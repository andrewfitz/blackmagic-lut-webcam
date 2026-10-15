import AppKit
import CoreVideo
import Observation
import UniformTypeIdentifiers

struct InputDevice: Identifiable {
  let id: String
  let name: String
}

@MainActor @Observable
final class AppModel {
  var devices: [InputDevice] = []
  /// Descriptors and selection are coordinated as a collection. The selected
  /// session still follows the established one-feed capture path.
  var feedDescriptors: [FeedDescriptor] { feedCoordinator.descriptors }
  var selectedFeedID: FeedID { feedCoordinator.selectedFeedID }

  /// The virtual-camera topology is a persisted app setting. UI callers use
  /// this property instead of reaching into FeedCoordinator so that changing
  /// the output route always updates the shared registry and preferences.
  var outputMode: FeedOutputMode {
    get { feedCoordinator.outputMode }
    set { setOutputMode(newValue) }
  }

  /// Switcher state is kept on the same coordinator that consumes frames. The
  /// value is exposed as a snapshot for SwiftUI bindings; mutations should go
  /// through `updateSwitcher` to keep the frame route and disk state aligned.
  var switcherSettings: SwitcherSettings { feedCoordinator.switcher }
  var switcherSelectedFeedID: FeedID? { feedCoordinator.switcher.selectedFeedID }
  var switcherPendingFeedID: FeedID? { feedCoordinator.programOutput.pendingFeedID }
  var switcherStatus: String { feedCoordinator.switcherCoordinator.statusMessage }

  var canEditFeedTopology: Bool { !running && !loading }
  var selectedFeedName: String {
    feedCoordinator.selectedDescriptor.name
  }

  var selectedDevice = "" { didSet { if selectedDevice != oldValue { saveSettings() } } }
  var configuration = PipelineConfiguration() {
    didSet {
      guard configuration != oldValue, !restoringSettings else { return }
      if lutLoaded || lutBookmark == nil { rememberedLUTEnabled = configuration.applyLUT }
      saveSettings()
      if running { reconfigure() }
    }
  }
  var gamut = "S-Gamut3.Cine / S-Log3" { didSet { if gamut != oldValue { saveSettings() } } }
  var pipelineEnabled = true {
    didSet {
      guard pipelineEnabled != oldValue else { return }
      saveSettings()
      if running { reconfigure() }
    }
  }
  var previewEnabled = true {
    didSet {
      guard previewEnabled != oldValue else { return }
      saveSettings()
      if !previewEnabled { previewReady = false }
      capture.setPreviewEnabled(previewEnabled)
    }
  }
  var automaticFeedEnabled = false {
    didSet {
      guard automaticFeedEnabled != oldValue, !restoringSettings else { return }
      saveSettings()
      automaticPolicy = AutomaticFeedPolicy()
      cameraDemandError = nil
      if automaticFeedEnabled { demandMonitor.start() }
      else { demandMonitor.stop() }
    }
  }
  private(set) var cameraDemandError: String?
  var lutTitle = "No LUT loaded"
  private(set) var lutFileName: String?
  private(set) var lutError: String?
  var lutLoaded = false
  var running = false
  var previewReady = false
  var loading = false
  var update = CaptureUpdate(message: "Select the UltraStudio input and start the feed. LUT loading is optional.")
  let installer = ExtensionInstaller()
  let previewRenderer: VideoPreviewRenderer
  let miniPreviewRenderer: VideoPreviewRenderer
  private let capture: CaptureController
  let recordingModel: RecordingModel
  private let feedCoordinator: FeedCoordinator
  private let settingsStore: AppSettingsStore
  private let virtualCameraRegistryStore: VirtualCameraRegistryStore
  private let lutLoader: LUTFileLoader
  private var restoringSettings = true
  private var lutBookmark: Data?
  private var rememberedLUTEnabled = false
  private let demandMonitor = CameraDemandMonitor()
  private var automaticPolicy = AutomaticFeedPolicy()
  private var persistedSnapshot = AppSettingsSnapshot()

  init(settingsStore: AppSettingsStore? = nil, lutLoader: LUTFileLoader = LUTFileLoader(),
       registryStore: VirtualCameraRegistryStore? = nil) {
    let store = settingsStore ?? AppSettingsStore()
    self.settingsStore = store
    self.virtualCameraRegistryStore = registryStore ?? VirtualCameraRegistryStore()
    let snapshot = store.loadSnapshot()
    persistedSnapshot = snapshot

    let renderer = VideoPreviewRenderer()
    let miniRenderer = VideoPreviewRenderer()
    let primaryCapture = CaptureController(previewRenderer: renderer, additionalPreviewRenderers: [miniRenderer])
    let capturePool = FeedCapturePool(initial: [snapshot.selectedFeedID: primaryCapture])
    feedCoordinator = FeedCoordinator(snapshot: snapshot, capturePool: capturePool)
    let coordinator = feedCoordinator
    previewRenderer = renderer
    miniPreviewRenderer = miniRenderer
    capture = primaryCapture
    recordingModel = RecordingModel(
      feeds: feedCoordinator.descriptors.map { RecordingFeedDescriptor(id: $0.id, name: $0.name) },
      driver: NativeRecordingSessionDriver(capture: primaryCapture, rawAudioCallbackAvailable: true,
        captureForFeed: { id in coordinator.capture(for: id) }))
    self.lutLoader = lutLoader
    let savedFeed = snapshot.selectedFeed ?? FeedDescriptor()
    selectedDevice = savedFeed.selectedDevice
    configuration = savedFeed.configuration
    rememberedLUTEnabled = savedFeed.applyLUT
    // Saved intent is restored only after the file and GPU upload succeed.
    configuration.applyLUT = false
    gamut = savedFeed.gamut
    pipelineEnabled = savedFeed.pipelineEnabled
    previewEnabled = savedFeed.previewEnabled
    automaticFeedEnabled = savedFeed.automaticFeed
    lutBookmark = savedFeed.lutBookmark
    restoringSettings = false
    publishVirtualCameraRegistry(snapshot)
    capture.setPreviewEnabled(previewEnabled)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    feedCoordinator.setCameraOutputEnabled(feedID: snapshot.selectedFeedID,
      enabled: snapshot.outputMode != .program)
    installProcessedFrameHandler(for: snapshot.selectedFeedID)
    capture.onUpdate = { [weak self] update in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.update = update
        let previewReady = self.previewEnabled && update.previewDelivered
        if self.previewReady != previewReady { self.previewReady = previewReady }
        if let inputFast = update.inputFast, self.configuration.inputFast != inputFast {
          self.restoringSettings = true
          self.configuration.inputFast = inputFast
          self.restoringSettings = false
        }
        if update.stopped {
          self.feedCoordinator.selectedSession.stop()
          self.recordingModel.stopAll()
          self.running = false
        }
      }
    }
    refresh()
    if let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
    demandMonitor.onRouteChange = { [weak self] change in
      guard let self, self.automaticFeedEnabled,
        change.route.id == self.automaticDemandRouteID else { return }
      self.cameraDemandError = change.error
      self.automaticPolicy.demand(change.requested == true)
      self.reconcileAutomaticFeed()
    }
    if automaticFeedEnabled { demandMonitor.start() }
  }

  func refresh() {
    do {
      devices = try UDLBackend.devices().map { InputDevice(id: $0.identifier, name: $0.name) }
    } catch { devices = []; update.message = error.localizedDescription }
    if !devices.isEmpty, !devices.contains(where: { $0.id == selectedDevice }) {
      selectedDevice = devices.first!.id
    }
    if automaticFeedEnabled, !restoringSettings {
      demandMonitor.refresh()
      reconcileAutomaticFeed()
    }
  }

  func chooseLUT() {
    guard !loading else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose an FX3 log-to-Rec.709 LUT"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    lutError = nil
    loading = true
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.load(url: url)
        self?.uploadLUT(loaded, enable: true)
      } catch { self?.lutLoadFailed(error, restoring: false) }
    }
  }

  private func restoreLUT(bookmark: Data) {
    lutError = nil
    loading = true
    update.message = "Restoring saved LUT…"
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.restore(bookmark: bookmark)
        guard let self else { return }
        self.uploadLUT(loaded, enable: self.rememberedLUTEnabled, restoring: true)
      } catch { self?.lutLoadFailed(error, restoring: true) }
    }
  }

  private func uploadLUT(_ loaded: LoadedLUT, enable: Bool, restoring: Bool = false) {
    capture.load(loaded.cube) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch result {
        case .success:
          self.lutError = nil
          self.loading = false
          self.lutLoaded = true
          self.lutBookmark = loaded.bookmark
          self.rememberedLUTEnabled = enable
          self.configuration.applyLUT = enable
          self.lutTitle = "\(loaded.cube.title) · \(loaded.cube.dimension)³"
          self.lutFileName = loaded.fileName
          self.saveSettings()
          self.update.message = "LUT loaded. Confirm it expects \(self.gamut) and outputs Rec.709."
          self.reconcileAutomaticFeed()
        case .failure(let error): self.lutLoadFailed(error, restoring: restoring)
        }
      }
    }
  }

  private func lutLoadFailed(_ error: Error, restoring: Bool) {
    loading = false
    // Keep the last saved bookmark and an already-loaded LUT. A missing moved
    // file is recoverable by choosing it again; it does not erase preferences.
    if restoring { lutTitle = "Saved LUT unavailable" }
    let message = "\(restoring ? "Saved LUT could not be restored" : "LUT was not changed"): \(error.localizedDescription)"
    lutError = message
    update.message = message
    reconcileAutomaticFeed()
  }

  /// Selects a feed and loads its persisted controls into the app-level
  /// bindings. Selection is a state transition, so pending edits on the
  /// previous feed are committed before the new descriptor is applied.
  @discardableResult
  func selectFeed(_ id: FeedID) -> Bool {
    guard canEditFeedTopology,
      feedCoordinator.descriptors.contains(where: { $0.id == id }) else { return false }
    saveSettings()
    guard feedCoordinator.select(id) else { return false }
    let descriptor = feedCoordinator.selectedDescriptor
    applySelectedDescriptor(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    installProcessedFrameHandler(for: id)
    return true
  }

  /// Adds an idle feed, persists the new topology, and selects it so the UI
  /// immediately edits the new feed's independent settings.
  @discardableResult
  func addFeed(name: String? = nil) -> FeedID? {
    guard canEditFeedTopology else { return nil }
    saveSettings()
    let id = feedCoordinator.add(name: name)
    guard selectFeed(id) else { return nil }
    saveSettings()
    return id
  }

  /// Removes an idle feed and selects the first remaining descriptor when the
  /// removed feed was active. The coordinator owns the running/removal guard.
  @discardableResult
  func removeFeed(_ id: FeedID) -> Bool {
    guard canEditFeedTopology else { return false }
    let wasSelected = id == selectedFeedID
    saveSettings()
    guard feedCoordinator.remove(id) else { return false }
    if wasSelected { applySelectedDescriptor(feedCoordinator.selectedDescriptor) }
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    return true
  }

  @discardableResult
  func renameFeed(_ id: FeedID, name: String) -> Bool {
    guard canEditFeedTopology,
      let existing = feedCoordinator.descriptors.first(where: { $0.id == id }) else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var updated = existing
    updated.name = trimmed
    feedCoordinator.update(updated)
    saveSettings()
    return true
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard !running, feedCoordinator.outputMode != mode else { return }
    saveSettings()
    feedCoordinator.setOutputMode(mode)
    saveSettings()
  }

  /// Applies switcher controls atomically to the live Program route and its
  /// persisted snapshot. Invalid feed IDs are normalized by the coordinator.
  func updateSwitcher(_ settings: SwitcherSettings) {
    guard !restoringSettings else { return }
    feedCoordinator.setSwitcher(settings)
    saveSettings()
  }

  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    let result = feedCoordinator.requestProgramCut(to: feedID)
    if case .rejectedMissingSource = result { return result }
    saveSettings()
    return result
  }

  private func applySelectedDescriptor(_ descriptor: FeedDescriptor) {
    restoringSettings = true
    selectedDevice = descriptor.selectedDevice
    configuration = descriptor.configuration
    rememberedLUTEnabled = descriptor.applyLUT
    configuration.applyLUT = false
    gamut = descriptor.gamut
    pipelineEnabled = descriptor.pipelineEnabled
    previewEnabled = descriptor.previewEnabled
    automaticFeedEnabled = descriptor.automaticFeed
    lutBookmark = descriptor.lutBookmark
    lutLoaded = false
    lutTitle = "No LUT loaded"
    lutFileName = nil
    lutError = nil
    restoringSettings = false
    if let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
    capture.setPreviewEnabled(previewEnabled)
  }

  func saveSettings() {
    guard !restoringSettings else { return }
    let oldName = feedCoordinator.selectedDescriptor.name
    let descriptor = FeedDescriptor(id: selectedFeedID, name: oldName, selectedDevice: selectedDevice,
      applyLUT: lutLoaded ? configuration.applyLUT : rememberedLUTEnabled,
      downscale: configuration.downscale, convertTo420: configuration.convertTo420,
      reduceFrameRate: configuration.reduceFrameRate, gamut: gamut,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled, lutBookmark: lutBookmark,
      automaticFeed: automaticFeedEnabled)
    feedCoordinator.update(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    publishVirtualCameraRegistry(persistedSnapshot)
  }

  /// Publishes the complete feed topology in one transaction. The camera
  /// extension reads this snapshot from the shared app group and can retain
  /// existing CMIO devices until their clients release them during reconcile.
  private func publishVirtualCameraRegistry(_ snapshot: AppSettingsSnapshot) {
    let previous = virtualCameraRegistryStore.load()
    let candidate = VirtualCameraRegistrySnapshot.forFeeds(snapshot.feeds,
      outputMode: snapshot.outputMode, previous: previous)
    do {
      try virtualCameraRegistryStore.save(candidate)
    } catch {
      update.message = "Virtual cameras could not be updated: \(error.localizedDescription)"
    }
  }

  private var effectiveConfiguration: PipelineConfiguration {
    var snapshot = configuration
    snapshot.applyLUT = snapshot.applyLUT && lutLoaded
    return snapshot
  }

  private func reconfigure() {
    update.pipelineEnabledApplied = nil
    update.output = ""
    capture.reconfigure(configuration: effectiveConfiguration, pipelineEnabled: pipelineEnabled)
  }

  var canStartFeed: Bool {
    !running && !loading && devices.contains { $0.id == selectedDevice }
  }

  func start() {
    guard !automaticFeedEnabled else { return }
    startFeed()
  }

  private func startFeed() {
    guard canStartFeed else { return }
    if feedCoordinator.outputMode == .program {
      // Start every configured source that has a device assignment. The
      // selected feed keeps the existing preview controller; additional
      // sources run headless and publish only into the Program route.
      for descriptor in feedCoordinator.descriptors where descriptor.enabled &&
        descriptor.id != selectedFeedID && !descriptor.selectedDevice.isEmpty {
        installProcessedFrameHandler(for: descriptor.id)
        feedCoordinator.setCameraOutputEnabled(feedID: descriptor.id, enabled: false)
        _ = feedCoordinator.startCapture(feedID: descriptor.id,
          deviceID: descriptor.selectedDevice, configuration: descriptor.configuration,
          pipelineEnabled: descriptor.pipelineEnabled, previewEnabled: false)
      }
    }
    guard feedCoordinator.start(selectedFeedID) else { return }
    running = true
    previewReady = false
    update = CaptureUpdate(message: "Opening UltraStudio…")
    if feedCoordinator.outputMode == .program {
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: false)
      do {
        try feedCoordinator.setProgramOutputDemand(true, configuration: effectiveConfiguration,
          passthroughFormat: kCVPixelFormatType_422YpCbCr10)
      } catch {
        update.message = "Program camera unavailable: \(error.localizedDescription)"
      }
    } else {
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: true)
    }
    capture.start(feedID: selectedFeedID, deviceID: selectedDevice, configuration: effectiveConfiguration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
  }

  func stop() {
    running = false
    if feedCoordinator.outputMode == .program {
      try? feedCoordinator.setProgramOutputDemand(false, configuration: effectiveConfiguration,
        passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    }
    for descriptor in feedCoordinator.descriptors where descriptor.id != selectedFeedID {
      feedCoordinator.stopCapture(feedID: descriptor.id)
    }
    feedCoordinator.stop(selectedFeedID)
    recordingModel.stopAll()
    capture.stop()
  }

  private func installProcessedFrameHandler(for feedID: FeedID) {
    feedCoordinator.setProcessedFrameHandler(feedID: feedID) { [weak self] frame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        _ = self.feedCoordinator.publish(frame, to: feedID)
        self.feedCoordinator.pumpProgramOutput()
      }
    }
  }

  var cameraRequested: Bool { automaticPolicy.requested }

  private var automaticDemandRouteID: String {
    if feedCoordinator.outputMode == .program {
      return VirtualCameraDescriptor.program().id
    }
    return VirtualCameraDescriptor.feed(feedID: selectedFeedID.rawValue).id
  }

  var automaticFeedStatus: String {
    if let cameraDemandError { return cameraDemandError }
    if !cameraRequested { return "Waiting for a camera app. Capture and video processing are off." }
    if loading { return "Camera requested. Restoring your LUT…" }
    if running { return "Camera in use. Stops when the last camera app closes it." }
    if !devices.contains(where: { $0.id == selectedDevice }) { return "Camera requested. Connect the UltraStudio and refresh inputs." }
    return "Camera requested. Feed stopped; retry or reopen the camera in your app."
  }

  func retryAutomaticFeed() {
    automaticPolicy.retry()
    // `start()` is idempotent while the monitor is healthy, and retries the
    // listener registration after an initial setup failure. `refresh()` alone
    // is a no-op in that failed state because the monitor is disabled there.
    demandMonitor.start()
    demandMonitor.refresh()
    reconcileAutomaticFeed()
  }

  private func reconcileAutomaticFeed() {
    guard automaticFeedEnabled else { return }
    switch automaticPolicy.action(ready: canStartFeed, running: running) {
    case .start: startFeed()
    case .stop: stop()
    case nil: break
    }
  }

  func resetPreview() {
    previewRenderer.flush()
    miniPreviewRenderer.flush()
  }
}

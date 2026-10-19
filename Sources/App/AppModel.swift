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
  var hideFromDock = false {
    didSet {
      guard hideFromDock != oldValue else { return }
      settingsStore.hideFromDock = hideFromDock
      NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }
  }
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

  var naturalTalkingHeadEnabled: Bool {
    get { feedCoordinator.switcher.naturalTalkingHead.enabled }
    set {
      guard !newValue || !running || outputMode == .program else { return }
      var settings = feedCoordinator.switcher
      if newValue, outputMode != .program { setOutputMode(.program) }
      settings.automatic = newValue
      settings.strategy = newValue ? .naturalTalkingHead : .manual
      settings.naturalTalkingHead.enabled = newValue
      updateSwitcher(settings)
    }
  }

  var naturalAnchorFeedID: FeedID? {
    get { feedCoordinator.switcher.naturalTalkingHead.anchorFeedID }
    set {
      var settings = feedCoordinator.switcher
      settings.naturalTalkingHead.anchorFeedID = newValue
      updateSwitcher(settings)
    }
  }

  var naturalEmphasisFeedID: FeedID? {
    get { feedCoordinator.switcher.naturalTalkingHead.emphasisFeedID }
    set {
      var settings = feedCoordinator.switcher
      settings.naturalTalkingHead.emphasisFeedID = newValue
      updateSwitcher(settings)
    }
  }

  var naturalDirectorStatus: String {
    if !naturalTalkingHeadEnabled { return "Disabled" }
    if autoSwitcherBridge != nil { return "Active · Rust director" }
    return running ? "Waiting for two enabled feeds" : "Starts with Program output"
  }

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
      // A live feed stays up under manual Start/Stop. Only the demand monitor
      // changes, so closing the camera app no longer stops a feed the user
      // has taken back.
      installAutomaticFeedMonitor()
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
  // The selected feed owns the capture controller used by the app-level
  // controls. This used to be permanently bound to the primary controller,
  // which left selection changes publishing frames from the wrong feed.
  private var capture: CaptureController
  let recordingModel: RecordingModel
  private let feedCoordinator: FeedCoordinator
  private let settingsStore: AppSettingsStore
  private let virtualCameraRegistryStore: VirtualCameraRegistryStore
  private let lutLoader: LUTFileLoader
  private var restoringSettings = true
  private var lutBookmark: Data?
  private var rememberedLUTEnabled = false
  // LUT parsing and GPU uploads are asynchronous. Invalidate an operation
  // whenever the selected feed or a newer load changes, so an old completion
  // cannot overwrite the current feed's settings.
  private var lutLoadGeneration: UInt64 = 0
  private let demandMonitor = CameraDemandMonitor()
  private var automaticPolicy = AutomaticFeedPolicy()
  private var persistedSnapshot = AppSettingsSnapshot()
  private var autoSwitcherBridge: AutoSwitcherBridge?
  private var autoSwitcherTimeline: AutoSwitcherTimelineRecorder?
  private var recordingTimelines: [FeedID: AutoSwitcherTimelineRecorder] = [:]
  private var pendingAutoDecisionID: UUID?
  private var pendingAutoTargetFeedID: FeedID?

  init(settingsStore: AppSettingsStore? = nil, lutLoader: LUTFileLoader = LUTFileLoader(),
       registryStore: VirtualCameraRegistryStore? = nil) {
    let store = settingsStore ?? AppSettingsStore()
    self.settingsStore = store
    hideFromDock = store.hideFromDock
    self.virtualCameraRegistryStore = registryStore ?? VirtualCameraRegistryStore()
    let snapshot = store.loadSnapshot()
    persistedSnapshot = snapshot

    let renderer = VideoPreviewRenderer()
    let miniRenderer = VideoPreviewRenderer()
    let initialFeedID = snapshot.feeds.first(where: { $0.id == snapshot.selectedFeedID && $0.enabled })?.id
      ?? snapshot.feeds.first(where: \.enabled)?.id
      ?? snapshot.feeds[0].id
    let primaryCapture = CaptureController(services: .live(feedID: initialFeedID),
      previewRenderer: renderer, additionalPreviewRenderers: [miniRenderer])
    let capturePool = FeedCapturePool(initial: [initialFeedID: primaryCapture], factory: { feedID in
      CaptureController(services: .live(feedID: feedID), previewRenderer: renderer,
        additionalPreviewRenderers: [miniRenderer])
    })
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
    recordingModel.onOutputFolderChanged = { [weak self] folder in
      self?.autoSwitcherTimeline?.setOutputFolder(folder)
    }
    recordingModel.onRecordingStarted = { [weak self] feedID, url in
      guard let self, let timeline = self.autoSwitcherTimeline else { return }
      self.recordingTimelines[feedID] = timeline
      timeline.recordingStarted(feedID: feedID, url: url, mediaStart: self.update.mediaTime)
    }
    recordingModel.onRecordingFinished = { [weak self] feedID, url in
      guard let self, let timeline = self.recordingTimelines.removeValue(forKey: feedID) else { return }
      timeline.recordingFinished(feedID: feedID, url: url, mediaEnd: self.update.mediaTime)
    }
    feedCoordinator.onProgramCutApplied = { [weak self] feedID, sourceTime, programTime in
      guard let self, let decisionID = self.pendingAutoDecisionID,
        self.pendingAutoTargetFeedID == feedID else { return }
      self.pendingAutoDecisionID = nil
      self.pendingAutoTargetFeedID = nil
      self.autoSwitcherTimeline?.recordApplied(decisionID: decisionID, target: feedID,
        sourceTime: sourceTime, programTime: programTime)
      // The director clock is the selected input's audio time. The frame that
      // landed the cut has a different source's video PTS, so acknowledging
      // with that PTS moves the director onto the wrong timeline. Nil keeps
      // the shot start on the decision's own cut time.
      self.autoSwitcherBridge?.acknowledge(decisionID: decisionID, appliedAt: nil)
    }
    let savedFeed = snapshot.feeds.first(where: { $0.id == initialFeedID }) ?? FeedDescriptor()
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
    feedCoordinator.setCameraOutputEnabled(feedID: initialFeedID,
      enabled: snapshot.outputMode != .program)
    installProcessedFrameHandler(for: initialFeedID)
    installCaptureUpdateHandler(for: initialFeedID)
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
      devices = try UltracamBackend.devices().map { InputDevice(id: $0.identifier, name: $0.name) }
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
    lutLoadGeneration &+= 1
    let loadGeneration = lutLoadGeneration
    let feedID = selectedFeedID
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.load(url: url)
        self?.uploadLUT(loaded, enable: true, generation: loadGeneration, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: false, generation: loadGeneration, feedID: feedID) }
    }
  }

  private func restoreLUT(bookmark: Data) {
    lutError = nil
    loading = true
    update.message = "Restoring saved LUT…"
    lutLoadGeneration &+= 1
    let loadGeneration = lutLoadGeneration
    let feedID = selectedFeedID
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.restore(bookmark: bookmark)
        guard let self else { return }
        self.uploadLUT(loaded, enable: self.rememberedLUTEnabled, restoring: true,
          generation: loadGeneration, feedID: feedID)
      } catch { self?.lutLoadFailed(error, restoring: true, generation: loadGeneration, feedID: feedID) }
    }
  }

  private func uploadLUT(_ loaded: LoadedLUT, enable: Bool, restoring: Bool = false,
                         generation: UInt64, feedID: FeedID) {
    guard generation == lutLoadGeneration, feedID == selectedFeedID else { return }
    capture.load(loaded.cube) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard generation == self.lutLoadGeneration, feedID == self.selectedFeedID else { return }
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
        case .failure(let error):
          self.lutLoadFailed(error, restoring: restoring, generation: generation, feedID: feedID)
        }
      }
    }
  }

  private func lutLoadFailed(_ error: Error, restoring: Bool, generation: UInt64, feedID: FeedID) {
    guard generation == lutLoadGeneration, feedID == selectedFeedID else { return }
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
    capture = feedCoordinator.capture(for: id)
    let descriptor = feedCoordinator.selectedDescriptor
    applySelectedDescriptor(descriptor)
    persistedSnapshot = feedCoordinator.snapshot
    settingsStore.saveSnapshot(persistedSnapshot)
    installCaptureUpdateHandler(for: id)
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
    syncRecordingFeeds()
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
    syncRecordingFeeds()
    if wasSelected {
      capture = feedCoordinator.capture(for: feedCoordinator.selectedFeedID)
      applySelectedDescriptor(feedCoordinator.selectedDescriptor)
      installCaptureUpdateHandler(for: feedCoordinator.selectedFeedID)
      installProcessedFrameHandler(for: feedCoordinator.selectedFeedID)
    }
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
    syncRecordingFeeds()
    saveSettings()
    return true
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard !running, feedCoordinator.outputMode != mode else { return }
    saveSettings()
    feedCoordinator.setOutputMode(mode)
    saveSettings()
    reconcileAutoSwitcher()
  }

  /// Applies switcher controls atomically to the live Program route and its
  /// persisted snapshot. Invalid feed IDs are normalized by the coordinator.
  func updateSwitcher(_ settings: SwitcherSettings) {
    guard !restoringSettings else { return }
    // The Rust bridge is configured immutably at creation time. Recreate it
    // when a live setting changes so camera identities and timing thresholds
    // cannot diverge from the UI's persisted policy.
    if autoSwitcherBridge != nil { stopAutoSwitcher() }
    feedCoordinator.setSwitcher(settings)
    saveSettings()
    reconcileAutoSwitcher()
  }

  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    let oldDecisionID = pendingAutoDecisionID
    let result = feedCoordinator.requestProgramCut(to: feedID)
    if case .rejectedMissingSource = result { return result }
    if let oldDecisionID {
      pendingAutoDecisionID = nil
      pendingAutoTargetFeedID = nil
      autoSwitcherTimeline?.recordRejected(decisionID: oldDecisionID)
      autoSwitcherBridge?.reject(decisionID: oldDecisionID)
    }
    if case .queued = result {
      autoSwitcherBridge?.manualOverride(cameraID: feedID, at: directorClock())
    } else if case .coalesced = result {
      autoSwitcherBridge?.manualOverride(cameraID: feedID, at: directorClock())
    }
    saveSettings()
    return result
  }

  /// Audio packet time from the selected input. That is the clock the Rust
  /// director ticks, so manual cuts have to be expressed on it.
  private func directorClock() -> CMTime {
    update.audioPacketTime ?? update.mediaTime ?? .zero
  }

  private func applySelectedDescriptor(_ descriptor: FeedDescriptor) {
    lutLoadGeneration &+= 1
    // An in-flight load for the previous feed no longer owns this flag.
    // Leaving it true disables Start until that discarded load finishes.
    loading = false
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
    // Assignments above ran while restoring, so the automatic-feed didSet
    // did not retarget the demand monitor. Do that after the new descriptor
    // is in place, then restore this feed's LUT.
    installAutomaticFeedMonitor()
    if let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
    capture.setPreviewEnabled(previewEnabled)
  }

  /// Points camera-demand listening at the selected feed without starting or
  /// stopping capture. Each feed stores its own automatic-feed choice.
  private func installAutomaticFeedMonitor() {
    automaticPolicy = AutomaticFeedPolicy()
    cameraDemandError = nil
    demandMonitor.setRoutes(feedCoordinator.virtualCameraDescriptors)
    if automaticFeedEnabled { demandMonitor.start() }
    else { demandMonitor.stop() }
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

  private func syncRecordingFeeds() {
    recordingModel.updateFeeds(feedCoordinator.descriptors.map {
      RecordingFeedDescriptor(id: $0.id, name: $0.name)
    })
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
    guard running, feedCoordinator.outputMode == .program else { return }
    // The Program sink negotiates once. A later processing change has to
    // renegotiate that contract or every new frame is rejected.
    try? feedCoordinator.setProgramOutputDemand(true, configuration: effectiveConfiguration,
      passthroughFormat: kCVPixelFormatType_422YpCbCr10)
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
        installCaptureUpdateHandler(for: descriptor.id)
        installProcessedFrameHandler(for: descriptor.id)
        feedCoordinator.setProgramSourceHealth(descriptor.id, healthy: true)
        feedCoordinator.setCameraOutputEnabled(feedID: descriptor.id, enabled: false)
        // Apply LUT stays off until this controller has its own cube. The
        // saved flag alone makes the first frame fail with "Load a LUT".
        var headlessConfiguration = descriptor.configuration
        let applySavedLUT = headlessConfiguration.applyLUT
        headlessConfiguration.applyLUT = false
        _ = feedCoordinator.startCapture(feedID: descriptor.id,
          deviceID: descriptor.selectedDevice, configuration: headlessConfiguration,
          pipelineEnabled: descriptor.pipelineEnabled, previewEnabled: false)
        if applySavedLUT, let bookmark = descriptor.lutBookmark {
          restoreHeadlessLUT(feedID: descriptor.id, bookmark: bookmark,
            pipelineEnabled: descriptor.pipelineEnabled)
        }
      }
    }
    guard feedCoordinator.start(selectedFeedID) else { return }
    running = true
    previewReady = false
    update = CaptureUpdate(message: "Opening UltraStudio…")
    if feedCoordinator.outputMode == .program {
      feedCoordinator.setProgramSourceHealth(selectedFeedID, healthy: true)
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: false)
      do {
        try feedCoordinator.setProgramOutputDemand(true, configuration: effectiveConfiguration,
          passthroughFormat: kCVPixelFormatType_422YpCbCr10)
      } catch {
        update.message = "Program camera unavailable: \(error.localizedDescription)"
      }
      reconcileAutoSwitcher()
    } else {
      feedCoordinator.setCameraOutputEnabled(feedID: selectedFeedID, enabled: true)
    }
    capture.start(feedID: selectedFeedID, deviceID: selectedDevice, configuration: effectiveConfiguration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
  }

  func stop() {
    running = false
    previewReady = false
    if feedCoordinator.outputMode == .program {
      try? feedCoordinator.setProgramOutputDemand(false, configuration: effectiveConfiguration,
        passthroughFormat: kCVPixelFormatType_422YpCbCr10)
    }
    for descriptor in feedCoordinator.descriptors where descriptor.id != selectedFeedID {
      feedCoordinator.stopCapture(feedID: descriptor.id)
    }
    feedCoordinator.stop(selectedFeedID)
    recordingModel.stopAll()
    stopAutoSwitcher()
  }

  private func reconcileAutoSwitcher() {
    guard feedCoordinator.outputMode == .program,
      running,
      feedCoordinator.switcherCoordinator.settings.naturalTalkingHead.enabled,
      feedCoordinator.switcherCoordinator.settings.automatic,
      feedCoordinator.switcherCoordinator.settings.strategy == .naturalTalkingHead else {
      stopAutoSwitcher()
      return
    }
    var settings = feedCoordinator.switcherCoordinator.settings.naturalTalkingHead
    settings.normalizeForRuntime()
    let feeds = feedCoordinator.descriptors.filter {
      $0.enabled && !$0.selectedDevice.isEmpty && feedCoordinator.isFeedRunning($0.id)
    }
    let enabledIDs = Set(feeds.map(\.id))
    let anchor = settings.anchorFeedID.flatMap { enabledIDs.contains($0) ? $0 : nil }
      ?? feeds.first?.id
    let emphasis = settings.emphasisFeedID.flatMap { enabledIDs.contains($0) ? $0 : nil }
      ?? feeds.first(where: { $0.id != anchor })?.id
    guard let anchor, let emphasis, anchor != emphasis else {
      stopAutoSwitcher()
      return
    }
    if autoSwitcherBridge != nil { return }
    guard let bridge = AutoSwitcherBridge(settings: settings, anchor: anchor, emphasis: emphasis) else {
      update.message = "Natural Talking Head could not start its Rust director."
      return
    }
    autoSwitcherTimeline = AutoSwitcherTimelineRecorder(settings: settings, anchor: anchor,
      emphasis: emphasis, outputFolder: recordingModel.outputFolder)
    guard let timeline = autoSwitcherTimeline else { return }
    timeline.onError = { [weak self] message in
      self?.update.message = "Auto-switcher timeline: \(message)"
    }
    bridge.onAudioCue = { [weak self, weak timeline, weak bridge] cue in
      Task { @MainActor in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        timeline?.recordAudioCue(cue)
      }
    }
    bridge.onTranscriptCue = { [weak self, weak timeline, weak bridge] cue in
      Task { @MainActor in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        timeline?.recordTranscript(cue)
      }
    }
    bridge.onInstruction = { [weak self, weak bridge] instruction in
      Task { @MainActor [weak self] in
        guard let self, self.autoSwitcherBridge === bridge, self.running,
          self.feedCoordinator.outputMode == .program else { return }
        self.autoSwitcherTimeline?.recordInstruction(instruction,
          from: self.switcherSelectedFeedID)
        // `cutTime` is on the director's audio clock, not on the target
        // camera's video PTS. Using it as a frame bound waits for a timestamp
        // the target will never reach and drops the current program source.
        let result = self.feedCoordinator.requestProgramCut(to: instruction.targetCameraID,
          noEarlierThan: nil)
        switch result {
        case .queued, .coalesced:
          self.pendingAutoDecisionID = instruction.decisionID
          self.pendingAutoTargetFeedID = instruction.targetCameraID
        case .ignoredSameSource, .rejectedMissingSource:
          self.autoSwitcherTimeline?.recordRejected(decisionID: instruction.decisionID)
          bridge?.reject(decisionID: instruction.decisionID)
        }
      }
    }
    bridge.onError = { [weak self, weak bridge] message in
      Task { @MainActor [weak self] in
        guard let self, let bridge, self.autoSwitcherBridge === bridge else { return }
        self.autoSwitcherTimeline?.recordError(message)
        self.update.message = "Auto director: \(message)"
      }
    }
    bridge.onDecisionExpired = { [weak self, weak bridge] decisionID in
      Task { @MainActor [weak self] in
        guard let self, let bridge, self.autoSwitcherBridge === bridge,
          self.pendingAutoDecisionID == decisionID else { return }
        self.pendingAutoDecisionID = nil
        self.pendingAutoTargetFeedID = nil
        self.autoSwitcherTimeline?.recordExpired(decisionID: decisionID)
        self.feedCoordinator.cancelProgramCut()
      }
    }
    autoSwitcherBridge = bridge
    if let current = feedCoordinator.programOutput.selectedFeedID,
      (current == anchor || current == emphasis) {
      bridge.manualOverride(cameraID: current, at: update.mediaTime ?? .zero)
    }
  }

  private func stopAutoSwitcher() {
    pendingAutoDecisionID = nil
    pendingAutoTargetFeedID = nil
    // Stopping or reconfiguring the director must not leave its queued target
    // in the Program scheduler to switch after the UI has disabled automation.
    feedCoordinator.cancelProgramCut()
    autoSwitcherBridge?.stop()
    autoSwitcherBridge = nil
    autoSwitcherTimeline?.finish()
    autoSwitcherTimeline = nil
  }

  private func feedAutoSwitcherAudio(_ update: CaptureUpdate) {
    guard feedCoordinator.outputMode == .program,
      let time = update.mediaTime ?? update.audioPacketTime else { return }
    if autoSwitcherBridge == nil {
      _ = feedCoordinator.evaluateSwitcher(at: time)
      return
    }
    if update.audioPresent {
      autoSwitcherBridge?.ingestAudio(time: update.audioPacketTime ?? time,
        rms: Float(max(update.audioRMSLeft, update.audioRMSRight)),
        peak: Float(max(update.audioPeakLeft, update.audioPeakRight)),
        present: true)
    } else {
      autoSwitcherTimeline?.recordTick(time: time)
      autoSwitcherBridge?.tick(time: time)
    }
  }

  /// Delivers a timestamped ASR boundary to the active transcript-assisted
  /// director.  The app currently has no built-in speech recognizer, so an
  /// ASR adapter can call this entry point from its own callback pipeline.
  /// Validation and queue handoff are owned by `AutoSwitcherBridge`.
  @MainActor
  func ingestAutoSwitcherTranscript(segmentID: String, revision: UInt32,
                                    start: CMTime, end: CMTime, kind: String,
                                    confidence: Float, isFinal: Bool) {
    guard feedCoordinator.outputMode == .program, running,
      let bridge = autoSwitcherBridge else { return }
    bridge.ingestTranscript(segmentID: segmentID, revision: revision, start: start,
      end: end, kind: kind, confidence: confidence, isFinal: isFinal)
  }

  /// Routes status updates from the currently selected controller into the
  /// app model. Controllers can outlive a selection change while their stop
  /// work drains, so stale updates are ignored by feed identity.
  private func installCaptureUpdateHandler(for feedID: FeedID) {
    let controller = feedCoordinator.capture(for: feedID)
    controller.onUpdate = { [weak self] update in
      MainActor.assumeIsolated {
        guard let self else { return }
        if update.stopped {
          self.feedCoordinator.stopCapture(feedID: feedID)
          if self.selectedFeedID == feedID {
            if self.feedCoordinator.outputMode == .program {
              try? self.feedCoordinator.setProgramOutputDemand(false,
                configuration: self.effectiveConfiguration,
                passthroughFormat: kCVPixelFormatType_422YpCbCr10)
            }
            for descriptor in self.feedCoordinator.descriptors where descriptor.id != feedID {
              self.feedCoordinator.stopCapture(feedID: descriptor.id)
            }
            self.recordingModel.stopAll()
            self.running = false
            self.previewReady = false
            self.stopAutoSwitcher()
          } else {
            // A headless Program source can fail independently. Stop only its
            // recording; stopping the director here would take the surviving
            // cameras off automatic cuts while they are still live.
            self.recordingModel.stop(feedID: feedID)
            self.retireProgramSource(feedID)
          }
          return
        }
        guard self.selectedFeedID == feedID else { return }
        self.update = update
        self.feedAutoSwitcherAudio(update)
        let previewReady = self.previewEnabled && update.previewDelivered
        if self.previewReady != previewReady { self.previewReady = previewReady }
        if let inputFast = update.inputFast, self.configuration.inputFast != inputFast {
          self.restoringSettings = true
          self.configuration.inputFast = inputFast
          self.restoringSettings = false
        }
      }
    }
  }

  /// Loads one non-selected feed's saved LUT into that feed's controller, then
  /// enables Apply LUT. The camera is already running without the LUT.
  private func restoreHeadlessLUT(feedID: FeedID, bookmark: Data, pipelineEnabled: Bool) {
    Task { [weak self, lutLoader] in
      let loaded: LoadedLUT
      do { loaded = try await lutLoader.restore(bookmark: bookmark) }
      catch { return }
      await MainActor.run { [weak self] in
        guard let self, self.running, self.feedCoordinator.isFeedRunning(feedID) else { return }
        self.feedCoordinator.capture(for: feedID).load(loaded.cube) { [weak self] result in
          MainActor.assumeIsolated {
            guard let self, case .success = result, self.running,
              self.feedCoordinator.isFeedRunning(feedID),
              let descriptor = self.feedCoordinator.descriptors.first(where: { $0.id == feedID }),
              descriptor.applyLUT else { return }
            var configuration = descriptor.configuration
            configuration.applyLUT = true
            self.feedCoordinator.reconfigureCapture(feedID: feedID,
              configuration: configuration, pipelineEnabled: pipelineEnabled)
          }
        }
      }
    }
  }

  /// Removes one failed source from Program eligibility without ending the
  /// session. The director hears the same health change on its next tick.
  private func retireProgramSource(_ feedID: FeedID) {
    feedCoordinator.setProgramSourceHealth(feedID, healthy: false)
    // `self.update` is the selected input, which owns the director clock.
    // The stopped source's own timestamps are cleared and must not be used.
    // A zero sample still records health without moving that clock backward.
    autoSwitcherBridge?.setCameraHealth(cameraID: feedID, healthy: false, at: directorClock())
  }

  private func installProcessedFrameHandler(for feedID: FeedID) {
    feedCoordinator.setProcessedFrameHandler(feedID: feedID) { [weak self] frame in
      // FeedCoordinator invokes this handler on MainActor after validating
      // the capture generation, so publishing stays ordered with stop/start
      // transitions and cannot admit a stale frame into a new session.
      guard let self else { return }
      _ = self.feedCoordinator.publish(frame, to: feedID)
      self.feedCoordinator.pumpProgramOutput()
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

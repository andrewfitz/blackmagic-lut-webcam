import AppKit
import Observation
import UniformTypeIdentifiers

struct InputDevice: Identifiable {
  let id: String
  let name: String
}

@MainActor @Observable
final class AppModel {
  var devices: [InputDevice] = []
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
  var lutTitle = "No LUT loaded"
  private(set) var lutFileName: String?
  var lutLoaded = false
  var running = false
  var previewReady = false
  var loading = false
  var update = CaptureUpdate(message: "Select the UltraStudio input and start the feed. LUT loading is optional.")
  let installer = ExtensionInstaller()
  let previewRenderer: VideoPreviewRenderer
  let miniPreviewRenderer: VideoPreviewRenderer
  private let capture: CaptureController
  private let settingsStore: AppSettingsStore
  private let lutLoader: LUTFileLoader
  private var restoringSettings = true
  private var lutBookmark: Data?
  private var rememberedLUTEnabled = false

  init(settingsStore: AppSettingsStore? = nil, lutLoader: LUTFileLoader = LUTFileLoader()) {
    let renderer = VideoPreviewRenderer()
    let miniRenderer = VideoPreviewRenderer()
    previewRenderer = renderer
    miniPreviewRenderer = miniRenderer
    capture = CaptureController(previewRenderer: renderer, additionalPreviewRenderers: [miniRenderer])
    self.settingsStore = settingsStore ?? AppSettingsStore()
    self.lutLoader = lutLoader
    let saved = self.settingsStore.load()
    selectedDevice = saved.selectedDevice
    configuration = saved.configuration
    rememberedLUTEnabled = saved.applyLUT
    // Saved intent is restored only after the file and GPU upload succeed.
    configuration.applyLUT = false
    gamut = saved.gamut
    pipelineEnabled = saved.pipelineEnabled
    previewEnabled = saved.previewEnabled
    lutBookmark = saved.lutBookmark
    restoringSettings = false
    capture.setPreviewEnabled(previewEnabled)
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
        if update.stopped { self.running = false }
      }
    }
    refresh()
    if let bookmark = lutBookmark { restoreLUT(bookmark: bookmark) }
  }

  func refresh() {
    do {
      devices = try UDLBackend.devices().map { InputDevice(id: $0.identifier, name: $0.name) }
    } catch { devices = []; update.message = error.localizedDescription }
    if !devices.isEmpty, !devices.contains(where: { $0.id == selectedDevice }) {
      selectedDevice = devices.first!.id
    }
  }

  func chooseLUT() {
    guard !loading else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose an FX3 log-to-Rec.709 LUT"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loading = true
    Task { [weak self, lutLoader] in
      do {
        let loaded = try await lutLoader.load(url: url)
        self?.uploadLUT(loaded, enable: true)
      } catch { self?.lutLoadFailed(error, restoring: false) }
    }
  }

  private func restoreLUT(bookmark: Data) {
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
          self.loading = false
          self.lutLoaded = true
          self.lutBookmark = loaded.bookmark
          self.rememberedLUTEnabled = enable
          self.configuration.applyLUT = enable
          self.lutTitle = "\(loaded.cube.title) · \(loaded.cube.dimension)³"
          self.lutFileName = loaded.fileName
          self.saveSettings()
          self.update.message = "LUT loaded. Confirm it expects \(self.gamut) and outputs Rec.709."
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
    update.message = "\(restoring ? "Saved LUT could not be restored" : "LUT was not changed"): \(error.localizedDescription)"
  }

  func saveSettings() {
    guard !restoringSettings else { return }
    settingsStore.save(AppSettings(selectedDevice: selectedDevice,
      applyLUT: lutLoaded ? configuration.applyLUT : rememberedLUTEnabled,
      downscale: configuration.downscale, convertTo420: configuration.convertTo420,
      reduceFrameRate: configuration.reduceFrameRate, gamut: gamut,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled, lutBookmark: lutBookmark))
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

  func start() {
    guard !selectedDevice.isEmpty, !running else { return }
    running = true
    previewReady = false
    update = CaptureUpdate(message: "Opening UltraStudio…")
    capture.start(deviceID: selectedDevice, configuration: effectiveConfiguration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
  }

  func stop() { running = false; capture.stop() }
}

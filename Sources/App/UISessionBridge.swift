import AppKit
import MonitorToolsCore
import SwiftUI

/// Interface-only preferences that are not part of the capture settings.
@MainActor @Observable
final class UIInterfaceState {
  private let defaults: UserDefaults
  var layout: UILayout { didSet { defaults.set(layout.rawValue, forKey: "ui.layout") } }
  var collapsed: Set<String> { didSet { defaults.set(Array(collapsed), forKey: "ui.collapsed") } }
  var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "ui.sidebar") } }
  var inspectorOpen = false
  /// Tests set this so confirmations are recorded instead of shown as modal alerts.
  var alertsDisabled = false
  /// A pending confirmation: the message and the action to run when confirmed.
  var confirmation: (message: String, action: UIAction)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    layout = UILayout(rawValue: defaults.string(forKey: "ui.layout") ?? "") ?? .sideBySide
    collapsed = Set(defaults.stringArray(forKey: "ui.collapsed") ?? [])
    sidebarVisible = defaults.object(forKey: "ui.sidebar") as? Bool ?? true
  }
}

enum UIFormatLabels {
  /// "3840 × 2160 · v210 · 4:2:2 10-bit · 59.94 fps" → "2160p 59.94".
  static func shortFormat(_ label: String) -> String? {
    let parts = label.components(separatedBy: " · ")
    guard let size = parts.first, size.contains("×") else { return nil }
    let height = size.components(separatedBy: "×").last?.trimmingCharacters(in: .whitespaces) ?? ""
    let rate = parts.first { $0.hasSuffix("fps") }?.replacingOccurrences(of: " fps", with: "") ?? ""
    guard !height.isEmpty else { return nil }
    return rate.isEmpty ? "\(height)p" : "\(height)p \(rate)"
  }

  static func signal(running: Bool, deviceAvailable: Bool, update: CaptureUpdate?) -> UISignal {
    guard running else { return .none }
    guard let update else { return .connecting }
    let input = update.input
    if let format = shortFormat(input) { return .live(format: format) }
    let lowered = (input + " " + update.message).lowercased()
    if lowered.contains("unsupported") { return .unsupported(input) }
    if lowered.contains("no video signal") || lowered.contains("no hdmi") || input == "No signal" {
      return update.frames > 0 ? .noSignal : (deviceAvailable ? .connecting : .deviceMissing)
    }
    return deviceAvailable ? .connecting : .deviceMissing
  }
}

/// Copies AppModel and RecordingModel state into a `UISessionSnapshot` and
/// performs `UIAction`s against the existing models.
@MainActor
struct UISessionBridge {
  let model: AppModel
  let interface: UIInterfaceState
  /// Supplied by the hosting views so actions that open windows work in the app.
  var openWindow: (String) -> Void = { _ in }
  var openSettings: () -> Void = {}

  func snapshot() -> UISessionSnapshot {
    let recording = model.recordingModel
    let drives = UIRecordingLibrary.drives(for: model.feedDescriptors.map { recording.outputFolder(for: $0.id) },
      recordingRates: model.feedDescriptors.compactMap { descriptor -> (URL, Double)? in
        guard let folder = recording.outputFolder(for: descriptor.id),
          let state = recording.feeds.first(where: { $0.id == descriptor.id }),
          state.status == .recording || state.status == .paused else { return nil }
        return (folder, state.statistics?.videoMegabitsPerSecond ?? UIRecordingLibrary.nominalMegabits(codec: recording.codec, fast: true))
      })
    var cameras: [UICameraSnapshot] = []
    for descriptor in model.feedDescriptors {
      let id = descriptor.id
      let running = model.isCameraRunning(id)
      let update = running ? model.cameraUpdate(id) : nil
      let deviceAvailable = model.devices.contains { $0.id == descriptor.selectedDevice }
      let selected = id == model.selectedFeedID
      let state = recording.feeds.first { $0.id == id }
      let stats = state?.statistics
      let folder = recording.outputFolder(for: id)
      var camera = UICameraSnapshot(id: id.rawValue, name: descriptor.name)
      camera.inputName = model.devices.first { $0.id == descriptor.selectedDevice }?.name
      camera.deviceAvailable = deviceAvailable
      camera.running = running
      camera.signal = UIFormatLabels.signal(running: running, deviceAvailable: deviceAvailable, update: update)
      camera.outputFormat = update.flatMap { UIFormatLabels.shortFormat($0.output) }
      camera.applying = running && update != nil && update?.pipelineEnabledApplied == nil &&
        UIFormatLabels.shortFormat(update?.input ?? "") != nil
      camera.inUse = model.outputMode == .separateCameras && running && (model.cameraInUse(id) || update?.cameraOutputActive == true)
      camera.processing = selected ? model.pipelineEnabled : descriptor.pipelineEnabled
      let configuration = selected ? model.configuration : descriptor.configuration
      camera.effects = [selected ? (model.configuration.applyLUT || (!model.lutLoaded && descriptor.applyLUT)) : descriptor.applyLUT,
        configuration.downscale, configuration.convertTo420, configuration.reduceFrameRate]
      camera.lutName = selected ? (model.lutLoaded ? model.lutFileName ?? model.lutTitle : nil)
        : (descriptor.lutBookmark != nil ? "Saved LUT" : nil)
      camera.lutLoading = selected && model.loading
      camera.lutError = selected ? model.lutError : nil
      camera.gamut = selected ? model.gamut : descriptor.gamut
      camera.previewEnabled = descriptor.previewEnabled
      camera.previewError = update?.previewError
      camera.automaticStart = descriptor.automaticFeed
      camera.automaticStatus = selected && descriptor.automaticFeed ? model.automaticFeedStatus : nil
      camera.timecode = update?.timecode
      if let update {
        camera.audio = UIAudioLevels(present: update.audioPresent, peakLeft: update.audioPeakLeft,
          peakRight: update.audioPeakRight, rmsLeft: update.audioRMSLeft, rmsRight: update.audioRMSRight)
      }
      let monitor = model.monitorCoordinator.configuration(for: MonitorTargetID(id.rawValue))
      camera.activeTools = UIMonitorBridge.activeTools(monitor)
      camera.message = update?.message ?? ""
      var rec = UICameraRecording()
      switch state?.status ?? .idle {
      case .idle: rec.status = .idle
      case .recording: rec.status = .recording
      case .paused: rec.status = .paused
      case .finishing: rec.status = .finishing
      }
      rec.elapsed = stats?.elapsed ?? 0
      rec.fileBytes = Int64(stats?.fileBytes ?? 0)
      rec.megabitsPerSecond = stats?.videoMegabitsPerSecond ?? 0
      rec.droppedFrames = Int(clamping: stats?.droppedVideoFrames ?? 0)
      rec.failed = stats?.failed == true
      rec.error = state?.error ?? stats?.lastError
      rec.savedURL = state?.savedURL
      rec.savedFileName = state?.savedURL?.lastPathComponent
      rec.savedDuration = state?.savedURL != nil ? stats?.elapsed : nil
      rec.folderPath = folder?.path
      rec.folderIsCustom = recording.customOutputFolder(for: id) != nil
      rec.secondsLeft = folder.flatMap { url in drives.first { $0.name == UIRecordingLibrary.volumeName(for: url) }?.secondsLeft }
      camera.recording = rec
      cameras.append(camera)
    }
    var session = UISessionSnapshot()
    session.outputMode = model.outputMode == .program ? .program : .separate
    session.cameras = cameras
    session.selectedID = model.selectedFeedID.rawValue
    session.programInUse = model.programInUse
    session.onAirID = model.outputMode == .program ? model.switcherSelectedFeedID?.rawValue : nil
    session.pendingCutID = model.switcherPendingFeedID?.rawValue
    let switcher = model.switcherSettings
    session.autoSwitching = switcher.automatic
    session.autoHold = switcher.naturalTalkingHead.manualHold
    session.strategy = switcher.strategy
    session.strategyTitle = UIStrategy.title(switcher.strategy)
    session.shot = UIShotTiming(startedAt: model.programShotStartedAt, currentShot: model.programShotStartedAt.map { Date().timeIntervalSince($0) },
      minimum: switcher.naturalTalkingHead.minimumShotDuration,
      softMaximum: switcher.naturalTalkingHead.softMaximumShotDuration,
      maximum: switcher.naturalTalkingHead.maximumShotDuration)
    session.programFormatMismatch = model.programFormatMismatch
    session.recentCuts = model.recentCuts
    session.codecTitle = recording.codec.title
    session.timecodeTitle = UITimecode.title(recording.timecodeMode)
    session.defaultFolderPath = recording.outputFolder?.path
    session.drives = drives
    session.recentTakes = UIRecordingLibrary.cachedRecentTakes(in: model.feedDescriptors.compactMap { recording.outputFolder(for: $0.id) })
    session.interruptedTakes = recording.interruptedRecordings.map { UIInterruptedTake(id: $0.id.path, title: $0.title) }
    session.recoveringID = recording.recoveringID?.path
    session.recoveryMessage = recording.recoveryMessage
    session.install = UIInstallState(canRequestChanges: model.installer.canRequestChanges, pending: model.installer.pending,
      status: model.installer.status, unavailableReason: model.installer.unavailableReason,
      installed: UIExtensionDetector.isInstalled())
    session.canEditTopology = model.canEditFeedTopology
    session.layout = model.outputMode == .program || interface.layout != .programView ? interface.layout : .sideBySide
    session.collapsed = interface.collapsed
    session.sidebarVisible = interface.sidebarVisible
    session.inspectorOpen = interface.inspectorOpen
    return session
  }

  func presentation() -> UISessionPresentation { UIPresentationBuilder.session(snapshot()) }

  private func feedID(_ raw: String) -> FeedID { FeedID(rawValue: raw) }

  private func cameraID(number: Int) -> FeedID? {
    let descriptors = model.feedDescriptors
    return descriptors.indices.contains(number - 1) ? descriptors[number - 1].id : nil
  }

  /// Runs an action, asking for confirmation first when it would end a recording or on-air output.
  func send(_ action: UIAction, confirmed: Bool = false) {
    if !confirmed, let message = action.needsConfirmation(in: presentation()) {
      // The main window shows the confirmation. Without a visible main window
      // (menus or the menu bar item), ask with a standard alert instead.
      let mainVisible = NSApplication.shared.windows.contains {
        $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false)
      }
      if mainVisible || interface.alertsDisabled {
        interface.confirmation = (message, action)
        return
      }
      let alert = NSAlert()
      alert.messageText = message
      alert.alertStyle = .warning
      alert.addButton(withTitle: UISessionBridge.confirmTitle(for: action))
      alert.addButton(withTitle: "Cancel")
      if #available(macOS 11.0, *) { alert.buttons.first?.hasDestructiveAction = true }
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    perform(action)
  }

  func perform(_ action: UIAction) {
    let recording = model.recordingModel
    switch action {
    case .select(let id): _ = model.selectFeed(feedID(id))
    case .selectNumber(let number): if let id = cameraID(number: number) { _ = model.selectFeed(id) }
    case .setLayout(let layout): interface.layout = layout
    case .toggleCollapsed(let id):
      if interface.collapsed.contains(id) { interface.collapsed.remove(id) } else { interface.collapsed.insert(id) }
    case .setAllCollapsed(let collapsed):
      interface.collapsed = collapsed ? Set(model.feedDescriptors.map(\.id.rawValue)) : []
    case .toggleSidebar: interface.sidebarVisible.toggle()
    case .toggleInspector: interface.inspectorOpen.toggle()
    case .setInspectorOpen(let open): if interface.inspectorOpen != open { interface.inspectorOpen = open }
    case .setSidebarVisible(let visible): if interface.sidebarVisible != visible { interface.sidebarVisible = visible }
    case .showInspector(let id): _ = model.selectFeed(feedID(id)); interface.inspectorOpen = true
    case .startCamera(let id): model.startCamera(feedID(id))
    case .stopCamera(let id): model.stopCamera(feedID(id))
    case .startAllCameras: model.startAllCameras()
    case .stopAllCameras: model.stopAllCameras()
    case .setProcessing(let id, let on): model.updateCamera(feedID(id)) { $0.pipelineEnabled = on }
    case .setEffect(let id, let index, let on):
      model.updateCamera(feedID(id)) { descriptor in
        switch index {
        case 0: descriptor.applyLUT = on
        case 1: descriptor.downscale = on
        case 2: descriptor.convertTo420 = on
        case 3: descriptor.reduceFrameRate = on
        default: break
        }
      }
    case .chooseLUT(let id):
      if model.selectedFeedID.rawValue != id { _ = model.selectFeed(feedID(id)) }
      model.chooseLUT()
    case .setGamut(let id, let gamut): model.updateCamera(feedID(id)) { $0.gamut = gamut }
    case .setInput(let id, let device): model.updateCamera(feedID(id)) { $0.selectedDevice = device }
    case .refreshInputs: model.refresh()
    case .setPreviewEnabled(let id, let on): model.updateCamera(feedID(id)) { $0.previewEnabled = on }
    case .setAutomaticStart(let id, let on): model.updateCamera(feedID(id)) { $0.automaticFeed = on }
    case .retryAutomaticStart: model.retryAutomaticFeed()
    case .retryPreview: model.resetPreview()
    case .addCamera: _ = model.addFeed()
    case .removeCamera(let id): _ = model.removeFeed(feedID(id))
    case .renameCamera(let id, let name): _ = model.renameFeed(feedID(id), name: name)
    case .cut(let id): _ = model.requestProgramCut(to: feedID(id))
    case .cutNumber(let number): if let id = cameraID(number: number) { _ = model.requestProgramCut(to: id) }
    case .setAutoSwitching(let on):
      var settings = model.switcherSettings
      settings.automatic = on
      settings.naturalTalkingHead.enabled = on && settings.strategy == .naturalTalkingHead
      model.updateSwitcher(settings)
    case .setAutoHold(let hold): model.setAutoHold(hold)
    case .setStrategy(let strategy):
      var settings = model.switcherSettings
      settings.strategy = strategy
      settings.naturalTalkingHead.enabled = settings.automatic && strategy == .naturalTalkingHead
      model.updateSwitcher(settings)
    case .setOutputMode(let mode): model.setOutputMode(mode == .program ? .program : .separateCameras)
    case .toggleRecording(let id):
      let fid = feedID(id)
      switch recording.feeds.first(where: { $0.id == fid })?.status ?? .idle {
      case .idle: recording.record(feedID: fid)
      case .recording, .paused: recording.stop(feedID: fid)
      case .finishing: break
      }
    case .pauseOrResume(let id):
      let fid = feedID(id)
      switch recording.feeds.first(where: { $0.id == fid })?.status ?? .idle {
      case .recording: recording.pause(feedID: fid)
      case .paused: recording.resume(feedID: fid)
      default: break
      }
    case .recordAll: recording.recordAll()
    case .stopAllRecordings: recording.stopAll()
    case .pauseAll: recording.pauseAll()
    case .toggleRecordingSelected: perform(.toggleRecording(cameraID: model.selectedFeedID.rawValue))
    case .chooseRecordingFolder(let id): UIPanels.chooseFolder(model: model, cameraID: id.map(feedID))
    case .useDefaultFolder(let id): recording.setOutputFolder(nil, for: feedID(id))
    case .clearDefaultFolder: recording.outputFolder = nil
    case .revealInFinder(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
    case .revealRecordings:
      if let folder = recording.outputFolder ?? model.feedDescriptors.compactMap({ recording.outputFolder(for: $0.id) }).first {
        NSWorkspace.shared.open(folder)
      }
    case .recover(let id): if let take = recording.interruptedRecordings.first(where: { $0.id.path == id }) { recording.recover(take) }
    case .toggleTool(let id, let tool):
      let gamut = model.descriptor(for: feedID(id))?.gamut ?? model.gamut
      UIMonitorBridge.toggle(tool, for: id, coordinator: model.monitorCoordinator,
        defaultSourceProfile: UIMonitorBridge.sourceProfile(forGamut: gamut))
    case .freeze, .toggleClean, .detachMonitor: UIMonitorBridge.perform(action, coordinator: model.monitorCoordinator)
    case .resetMonitorTools(let id):
      model.monitorCoordinator.setConfiguration(MonitorConfiguration(), for: MonitorTargetID(id))
    case .copyMonitorSettings(let from, let to):
      model.monitorCoordinator.copySettings(from: MonitorTargetID(from), to: MonitorTargetID(to))
    case .installCameraExtension: model.installer.install()
    case .removeCameraExtension: model.installer.uninstall()
    case .openSettings: openSettings()
    case .openDiagnostics: openWindow("diagnostics")
    case .openMainWindow:
      openWindow("main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    case .quit:
      model.saveSettings()
      NSApplication.shared.terminate(nil)
    }
  }
}

extension UISessionBridge {
  static func confirmTitle(for action: UIAction) -> String {
    switch action {
    case .stopAllCameras: return "Stop All Cameras"
    default: return "Stop Camera"
    }
  }
}

enum UIStrategy {
  static func title(_ strategy: SwitcherStrategy) -> String {
    switch strategy {
    case .manual: return "Manual"
    case .fixedInterval: return "Fixed interval"
    case .naturalTalkingHead: return "Natural talking head"
    case .dynamicAnalysis: return "Dynamic analysis (later)"
    }
  }
}

enum UITimecode {
  static func title(_ mode: RecordingTimecodeMode) -> String {
    switch mode {
    case .source: return "No Timecode Track"
    case .recordStart: return "Record Start"
    case .wallClock: return "Mac Clock"
    }
  }
}

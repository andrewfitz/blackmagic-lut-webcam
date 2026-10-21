import Foundation

/// Every user command the new interface can issue. Views never call the models
/// directly; they send one of these, so menus, toolbar, strips, the inspector
/// and the menu bar item share one implementation that can be tested.
enum UIAction: Sendable, Equatable {
  // Selection, layout and chrome
  case select(cameraID: String)
  case selectNumber(Int)
  case setLayout(UILayout)
  case toggleCollapsed(cameraID: String)
  case setAllCollapsed(Bool)
  case toggleSidebar
  case toggleInspector
  case showInspector(cameraID: String)

  // Cameras (capture and output)
  case startCamera(cameraID: String)
  case stopCamera(cameraID: String)
  case startAllCameras
  case stopAllCameras
  case setProcessing(cameraID: String, Bool)
  case setEffect(cameraID: String, index: Int, Bool)
  case chooseLUT(cameraID: String)
  case setGamut(cameraID: String, String)
  case setInput(cameraID: String, deviceID: String)
  case refreshInputs
  case setPreviewEnabled(cameraID: String, Bool)
  case setAutomaticStart(cameraID: String, Bool)
  case retryAutomaticStart
  case retryPreview
  case addCamera
  case removeCamera(cameraID: String)
  case renameCamera(cameraID: String, name: String)

  // Program
  case cut(cameraID: String)
  case cutNumber(Int)
  case setAutoSwitching(Bool)
  case setAutoHold(Bool)
  case setStrategy(SwitcherStrategy)
  case setOutputMode(UIOutputMode)

  // Recording
  case toggleRecording(cameraID: String)
  case pauseOrResume(cameraID: String)
  case recordAll
  case stopAllRecordings
  case pauseAll
  case toggleRecordingSelected
  case chooseRecordingFolder(cameraID: String?)
  case useDefaultFolder(cameraID: String)
  case clearDefaultFolder
  case revealInFinder(URL)
  case revealRecordings
  case recover(id: String)

  // Monitor
  case toggleTool(cameraID: String, UIMonitorTool)
  case freeze(cameraID: String)
  case toggleClean(cameraID: String)
  case detachMonitor(cameraID: String)
  case resetMonitorTools(cameraID: String)
  case copyMonitorSettings(from: String, to: String)

  // App
  case installCameraExtension
  case removeCameraExtension
  case openSettings
  case openDiagnostics
  case openMainWindow
  case quit
}

extension UIAction {
  /// Actions that end a recording or interrupt an on-air camera need a confirmation first.
  func needsConfirmation(in presentation: UISessionPresentation) -> String? {
    switch self {
    case .stopCamera(let id):
      guard let camera = presentation.cameras.first(where: { $0.id == id }), camera.stopNeedsConfirmation else { return nil }
      return camera.stopConfirmationMessage
    case .stopAllCameras:
      let recording = presentation.cameras.filter { $0.recordButtonActive || $0.pauseTitle == "Resume" }
      let onAir = presentation.cameras.contains { $0.tally == .onAir }
      guard !recording.isEmpty || onAir else { return nil }
      var parts: [String] = []
      if !recording.isEmpty { parts.append("\(recording.count == 1 ? "1 recording ends" : "\(recording.count) recordings end")") }
      if onAir { parts.append("on-air video stops") }
      return "Stop all cameras? " + parts.joined(separator: " and ") + "."
    default:
      return nil
    }
  }
}

import Foundation

// The new interface renders a presentation derived from one plain snapshot of
// the app's state. The snapshot is copied from AppModel and RecordingModel;
// the derivation below is pure, so every label, tally and enablement rule can
// be tested without capture hardware, SwiftUI or AppKit.

// MARK: - Snapshot

enum UIOutputMode: String, Sendable, Equatable { case separate, program }

enum UILayout: String, CaseIterable, Sendable, Equatable {
  case single, sideBySide, programView, fourUp
  var title: String {
    switch self {
    case .single: return "Single"
    case .sideBySide: return "Side by Side"
    case .programView: return "Program View"
    case .fourUp: return "Four Up"
    }
  }
  var symbol: String {
    switch self {
    case .single: return "rectangle"
    case .sideBySide: return "rectangle.split.2x1"
    case .programView: return "tv"
    case .fourUp: return "square.grid.2x2"
    }
  }
}

enum UIRecordingStatus: String, Sendable, Equatable { case idle, recording, paused, finishing }

enum UISignal: Sendable, Equatable {
  /// The camera is not capturing.
  case none
  /// Capture is running but no frame has arrived yet.
  case connecting
  case live(format: String)
  case noSignal
  case unsupported(String)
  case deviceMissing
}

enum UIMonitorTool: Int, CaseIterable, Sendable, Equatable {
  case guides, zebra, falseColor, focus, scopes
  var title: String {
    switch self {
    case .guides: return "Guides"
    case .zebra: return "Zebra"
    case .falseColor: return "False Color"
    case .focus: return "Focus Peaking"
    case .scopes: return "Scopes"
    }
  }
  var symbol: String {
    switch self {
    case .guides: return "squareshape.split.3x3"
    case .zebra: return "line.diagonal"
    case .falseColor: return "paintpalette"
    case .focus: return "scope"
    case .scopes: return "waveform.path.ecg"
    }
  }
}

struct UIAudioLevels: Sendable, Equatable {
  var present = false
  var peakLeft = 0.0, peakRight = 0.0, rmsLeft = 0.0, rmsRight = 0.0
}

struct UICameraRecording: Sendable, Equatable {
  var status: UIRecordingStatus = .idle
  var elapsed: TimeInterval = 0
  var fileBytes: Int64 = 0
  var megabitsPerSecond: Double = 0
  var droppedFrames = 0
  var failed = false
  var error: String?
  /// The most recent finished take, kept until the next take starts.
  var savedFileName: String?
  var savedURL: URL?
  var savedDuration: TimeInterval?
  var folderPath: String?
  var folderIsCustom = false
  /// Seconds of recording left on this camera's destination volume, if known.
  var secondsLeft: TimeInterval?
}

struct UICameraSnapshot: Sendable, Equatable, Identifiable {
  var id: String
  var name: String
  var inputName: String?
  var deviceAvailable = true
  var running = false
  var signal: UISignal = .none
  var outputFormat: String?
  /// True while an effect or processing change is renegotiating the output.
  var applying = false
  /// Separate mode: this camera's virtual camera has at least one client.
  var inUse = false
  var processing = true
  var effects: [Bool] = [false, true, true, false]
  var lutName: String?
  var lutLoading = false
  var lutError: String?
  var gamut = "S-Gamut3.Cine / S-Log3"
  var previewEnabled = true
  var previewError: String?
  var automaticStart = false
  var automaticStatus: String?
  /// Automatic mode tried to start this camera and failed; Retry is available.
  var automaticStartFailed = false
  var timecode: String?
  var audio = UIAudioLevels()
  var activeTools: Set<UIMonitorTool> = []
  var recording = UICameraRecording()
  var message = ""
}

struct UIShotTiming: Sendable, Equatable {
  /// When the camera now on Program went on air; views tick from here.
  var startedAt: Date?
  var currentShot: TimeInterval?
  var minimum: TimeInterval = 10
  var softMaximum: TimeInterval = 20
  var maximum: TimeInterval = 30
}

struct UICutRecord: Sendable, Equatable, Identifiable {
  var id = UUID()
  var at: Date
  var cameraID: String
  var cameraName: String
  var automatic: Bool
}

struct UIDrive: Sendable, Equatable, Identifiable {
  var id: String { name }
  var name: String
  var availableBytes: Int64
  var totalBytes: Int64
  var secondsLeft: TimeInterval?
}

struct UITake: Sendable, Equatable, Identifiable {
  var id: URL { url }
  var url: URL
  var name: String
  var date: Date
  var duration: TimeInterval?
}

struct UIInterruptedTake: Sendable, Equatable, Identifiable {
  var id: String
  var title: String
}

struct UIInstallState: Sendable, Equatable {
  var canRequestChanges = true
  var pending = false
  var status = ""
  var unavailableReason: String?
  /// True when an Ultracam camera device is present in the system.
  var installed = true
  var needsApproval: Bool { status.localizedCaseInsensitiveContains("approve") }
}

struct UISessionSnapshot: Sendable, Equatable {
  var outputMode: UIOutputMode = .separate
  var cameras: [UICameraSnapshot] = []
  var selectedID: String = ""
  var programInUse = false
  var onAirID: String?
  var pendingCutID: String?
  var autoSwitching = false
  var autoHold = false
  var strategy: SwitcherStrategy = .manual
  /// Natural talking head: the camera preferred for the wide/anchor shot, if fixed.
  var anchorID: String?
  /// Natural talking head: the camera preferred for emphasis, if fixed.
  var emphasisID: String?
  /// A picture is expanded from a grid layout; Restore Layout returns to it.
  var expandedFrom: UILayout?
  var strategyTitle = "Manual"
  var shot = UIShotTiming()
  var programFormatMismatch = false
  var recentCuts: [UICutRecord] = []
  var codecTitle = "ProRes 422 10-bit"
  var timecodeTitle = "Mac Clock"
  var defaultFolderPath: String?
  var drives: [UIDrive] = []
  var recentTakes: [UITake] = []
  var interruptedTakes: [UIInterruptedTake] = []
  var recoveringID: String?
  var recoveryMessage: String?
  var install = UIInstallState()
  var canEditTopology = true
  var layout: UILayout = .sideBySide
  var collapsed: Set<String> = []
  var sidebarVisible = true
  var inspectorOpen = false
}

// MARK: - Presentation

enum UITally: Sendable, Equatable {
  case none
  /// Red ring and "ON AIR": Program (with a client) or a separate camera in use.
  case onAir
  /// Program is selected but nothing is receiving it yet.
  case program
  /// A cut to this camera is pending (it lands on the next Program frame).
  case next
  var badge: String? {
    switch self {
    case .none: return nil
    case .onAir: return "ON AIR"
    case .program: return "PROGRAM"
    case .next: return "NEXT"
    }
  }
}

enum UITileState: Sendable, Equatable {
  case live, connecting, noSignal, unsupported(String), deviceMissing, stopped, previewHidden, updating
  /// True when the picture area shows video (tool chips and overlays only make sense then).
  var showsPicture: Bool { self == .live || self == .updating }
}

enum UIStripState: String, Sendable, Equatable {
  case ready, recording, paused, finishing, saved, noFolder, failed, recordingNoSignal, stopped, waiting, updating
}

enum UITone: String, Sendable, Equatable { case neutral, positive, warning, critical, onAir }

struct UIChip: Sendable, Equatable, Identifiable {
  var id: Int
  var title: String
  var isOn: Bool
  var enabled: Bool
  var help: String
}

struct UICameraPresentation: Sendable, Equatable, Identifiable {
  var id: String
  var number: Int
  var name: String
  var inputName: String
  var selected: Bool
  var collapsed: Bool
  var tally: UITally
  var tileState: UITileState
  var stripState: UIStripState
  var statusBadge: String
  var statusTone: UITone
  var recordTitle: String
  var recordDetail: String
  var recordTone: UITone
  var recordButtonActive: Bool
  var recordButtonEnabled: Bool
  var recordButtonHelp: String
  var pauseTitle: String?
  var sizeLine: String?
  var dropsLine: String?
  var dropsWarning: Bool
  var folderLine: String
  var timeLeftLine: String?
  var outputLine: String
  var outputInUse: Bool
  var showsCut: Bool
  var cutEnabled: Bool
  var chips: [UIChip]
  var processing: Bool
  var applying: Bool
  var canStart: Bool
  var canStop: Bool
  var stopNeedsConfirmation: Bool
  var stopConfirmationMessage: String
  var timecode: String
  var audio: UIAudioLevels
  var activeTools: [UIMonitorTool]
  var accessibilityLabel: String
  var lutError: String?
  var automaticStartFailed: Bool
}

enum UIRecordControl: Sendable, Equatable {
  case record(all: Bool, enabled: Bool)
  case stop(elapsed: String)
  case stopAll(count: Int, elapsed: String)
  var title: String {
    switch self {
    case .record(let all, _): return all ? "Record All" : "Record"
    case .stop: return "Stop Recording"
    case .stopAll(let count, _): return "Stop All (\(count))"
    }
  }
}

struct UICutButton: Sendable, Equatable, Identifiable {
  var id: String
  var number: Int
  var name: String
  var onAir: Bool
  var pending: Bool
  var enabled: Bool
}

struct UIStatusSegment: Sendable, Equatable, Identifiable {
  enum Kind: String, Sendable { case output, program, recording, audio, warning }
  var id: Kind { kind }
  var kind: Kind
  var text: String
  var tone: UITone
}

struct UISessionPresentation: Sendable, Equatable {
  var title: String
  var subtitle: String
  var cameras: [UICameraPresentation]
  var selected: UICameraPresentation?
  var outputMode: UIOutputMode
  var layouts: [UILayout]
  var layout: UILayout
  var recordControl: UIRecordControl
  var camerasRunning: Bool
  var camerasControlTitle: String
  var cutButtons: [UICutButton]
  var autoSwitching: Bool
  var statusSegments: [UIStatusSegment]
  var outputSummary: String
  var outputInUse: Bool
  var recordingSummary: String
  var menuBarIcon: UIMenuBarIcon
}

enum UIMenuBarIcon: String, Sendable, Equatable {
  case stopped, waiting, live, bypass, recording, attention
  var symbol: String {
    switch self {
    case .stopped, .waiting: return "video"
    case .live, .recording, .attention: return "video.fill"
    case .bypass: return "arrow.right.square"
    }
  }
  var accessibilityLabel: String {
    switch self {
    case .stopped: return "Ultracam, cameras stopped"
    case .waiting: return "Ultracam, waiting for a camera app"
    case .live: return "Ultracam, live with effects"
    case .bypass: return "Ultracam, live with complete bypass"
    case .recording: return "Ultracam, recording"
    case .attention: return "Ultracam needs attention"
    }
  }
}

// MARK: - Formatting

enum UIFormat {
  static func elapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
  }

  /// Short form for pills and status: "12:31", or "1:02:47" past an hour.
  static func shortElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded(.down)))
    if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) m" }
    return "\(minutes) min"
  }

  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  static func bitrate(_ megabits: Double) -> String {
    guard megabits.isFinite, megabits > 0 else { return "—" }
    return megabits >= 1000 ? String(format: "%.1f Gb/s", megabits / 1000) : String(format: "%.0f Mb/s", megabits)
  }
}

// MARK: - Derivation

enum UIPresentationBuilder {
  static let effectTitles = ["LUT", "1080p", "4:2:0", "29.97"]
  static let effectLongTitles = ["LUT", "Downscale to 1080p", "Color 4:2:0 8-bit", "Limit to 29.97 fps"]

  static func tally(for camera: UICameraSnapshot, in session: UISessionSnapshot) -> UITally {
    switch session.outputMode {
    case .program:
      if session.pendingCutID == camera.id && session.onAirID != camera.id { return .next }
      if session.onAirID == camera.id { return session.programInUse ? .onAir : .program }
      return .none
    case .separate:
      return camera.running && camera.inUse ? .onAir : .none
    }
  }

  static func tileState(for camera: UICameraSnapshot) -> UITileState {
    if !camera.deviceAvailable && !camera.running { return .deviceMissing }
    guard camera.running else { return .stopped }
    switch camera.signal {
    case .none, .connecting: return .connecting
    case .noSignal: return .noSignal
    case .unsupported(let mode): return .unsupported(mode)
    case .deviceMissing: return .deviceMissing
    case .live:
      if !camera.previewEnabled { return .previewHidden }
      return camera.applying ? .updating : .live
    }
  }

  static func stripState(for camera: UICameraSnapshot) -> UIStripState {
    let recording = camera.recording
    switch recording.status {
    case .finishing: return .finishing
    case .paused: return .paused
    case .recording:
      if case .noSignal = camera.signal { return .recordingNoSignal }
      return camera.applying ? .updating : .recording
    case .idle:
      if recording.failed || recording.error != nil { return .failed }
      if !camera.running { return .stopped }
      switch camera.signal {
      case .noSignal, .unsupported, .connecting, .none, .deviceMissing: return .waiting
      case .live: break
      }
      if recording.folderPath == nil { return .noFolder }
      if recording.savedFileName != nil { return .saved }
      return .ready
    }
  }

  static func camera(_ camera: UICameraSnapshot, index: Int, in session: UISessionSnapshot) -> UICameraPresentation {
    let tally = tally(for: camera, in: session)
    let tile = tileState(for: camera)
    let strip = stripState(for: camera)
    let rec = camera.recording
    let isRecording = rec.status == .recording || rec.status == .paused
    let liveFormat: String? = { if case .live(let format) = camera.signal { return format }; return nil }()

    let (statusBadge, statusTone): (String, UITone) = {
      if !camera.running { return camera.deviceAvailable ? ("Stopped", .neutral) : ("Input missing", .warning) }
      switch camera.signal {
      case .live(let format): return ("● \(format)", .positive)
      case .connecting, .none: return ("Starting…", .neutral)
      case .noSignal: return ("No signal", .warning)
      case .unsupported: return ("Unsupported format", .warning)
      case .deviceMissing: return ("Input disconnected", .warning)
      }
    }()

    let recordTitle: String
    var recordDetail = ""
    var recordTone: UITone = .neutral
    switch strip {
    case .recording, .updating: recordTitle = "Recording"; recordDetail = UIFormat.elapsed(rec.elapsed); recordTone = .critical
    case .recordingNoSignal:
      recordTitle = "Recording · no signal"; recordDetail = UIFormat.elapsed(rec.elapsed); recordTone = .warning
    case .paused: recordTitle = "Paused"; recordDetail = UIFormat.elapsed(rec.elapsed); recordTone = .warning
    case .finishing: recordTitle = "Finishing…"; recordDetail = "Writing the final fragment"
    case .saved:
      recordTitle = "Saved"; recordTone = .positive
      recordDetail = [rec.savedFileName, rec.savedDuration.map(UIFormat.shortElapsed)].compactMap { $0 }.joined(separator: " · ")
    case .noFolder: recordTitle = "No folder"; recordDetail = "Choose where \(camera.name) records"; recordTone = .warning
    case .failed:
      recordTitle = "Recording stopped"; recordDetail = rec.error ?? "The recording ended with an error."; recordTone = .critical
    case .stopped: recordTitle = "Camera stopped"; recordDetail = "Start the camera to record"
    case .waiting: recordTitle = "Waiting for HDMI"; recordDetail = "Record becomes available with a signal"
    case .ready: recordTitle = "Ready to record"; recordDetail = [liveFormat, session.codecTitle].compactMap { $0 }.joined(separator: " · ")
    }

    let canRecordNow = camera.running && liveFormat != nil && rec.folderPath != nil && rec.status == .idle
    let recordButtonActive = rec.status == .recording || rec.status == .paused
    let recordButtonEnabled = rec.status == .recording || rec.status == .paused || canRecordNow
    let recordHelp: String = {
      if rec.status == .recording || rec.status == .paused { return "Stop Recording (⌘R)" }
      if !camera.running { return "Start this camera before recording it." }
      if liveFormat == nil { return "Recording becomes available when a supported signal arrives." }
      if rec.folderPath == nil { return "Choose a recording folder first." }
      if rec.status == .finishing { return "Finishing the previous take." }
      return "Record (⌘R)"
    }()

    let chips = effectTitles.enumerated().map { index, title in
      UIChip(id: index, title: title, isOn: camera.effects.indices.contains(index) && camera.effects[index],
        enabled: index != 0 || camera.lutName != nil,
        help: index == 0
          ? (camera.lutName == nil ? "Load a .cube LUT to enable this effect." : "Apply the LUT. Doesn't change the camera output format.")
          : "\(effectLongTitles[index]). Changes the camera output format; the video updates briefly.")
    }

    let outputLine: String
    switch session.outputMode {
    case .program:
      if session.onAirID == camera.id {
        outputLine = session.programInUse ? "In Program · on air" : "In Program · no viewer yet"
      } else if session.pendingCutID == camera.id {
        outputLine = "Cut pending"
      } else {
        outputLine = "Program source"
      }
    case .separate:
      outputLine = "Ultracam · \(camera.name) · \(camera.inUse ? "In use" : "Not in use")"
    }

    let elapsedShort = UIFormat.shortElapsed(rec.elapsed)
    var labelParts = [camera.name]
    if let badge = tally.badge { labelParts.append(badge.capitalized) }
    if isRecording { labelParts.append(rec.status == .paused ? "recording paused at \(elapsedShort)" : "recording \(elapsedShort)") }
    if tile != .live { labelParts.append(statusBadge) }

    return UICameraPresentation(
      id: camera.id, number: index + 1, name: camera.name,
      inputName: camera.inputName ?? "No input selected",
      selected: camera.id == session.selectedID,
      collapsed: session.collapsed.contains(camera.id) || session.layout == .fourUp || session.layout == .programView,
      tally: tally, tileState: tile, stripState: strip,
      statusBadge: statusBadge, statusTone: statusTone,
      recordTitle: recordTitle, recordDetail: recordDetail, recordTone: recordTone,
      recordButtonActive: recordButtonActive, recordButtonEnabled: recordButtonEnabled, recordButtonHelp: recordHelp,
      pauseTitle: rec.status == .recording ? "Pause" : rec.status == .paused ? "Resume" : nil,
      sizeLine: isRecording ? "\(UIFormat.bytes(rec.fileBytes)) · \(UIFormat.bitrate(rec.megabitsPerSecond))" : nil,
      dropsLine: isRecording ? (rec.droppedFrames > 0 ? "\(rec.droppedFrames) dropped" : "0 dropped") : nil,
      dropsWarning: rec.droppedFrames > 0,
      folderLine: rec.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No recording folder",
      timeLeftLine: rec.secondsLeft.map { "\(UIFormat.duration($0)) left" },
      outputLine: outputLine,
      outputInUse: session.outputMode == .program ? (session.onAirID == camera.id && session.programInUse) : camera.inUse,
      showsCut: session.outputMode == .program && session.onAirID != camera.id,
      cutEnabled: session.outputMode == .program && camera.running && liveFormat != nil && session.onAirID != camera.id,
      chips: chips, processing: camera.processing, applying: camera.applying,
      canStart: !camera.running && camera.deviceAvailable,
      canStop: camera.running,
      stopNeedsConfirmation: camera.running && (isRecording || tally == .onAir),
      stopConfirmationMessage: stopMessage(camera: camera, recording: isRecording, onAir: tally == .onAir),
      timecode: camera.timecode ?? "—", audio: camera.audio,
      activeTools: UIMonitorTool.allCases.filter { camera.activeTools.contains($0) },
      accessibilityLabel: labelParts.joined(separator: ", "),
      lutError: camera.lutError, automaticStartFailed: camera.automaticStartFailed)
  }

  static func stopMessage(camera: UICameraSnapshot, recording: Bool, onAir: Bool) -> String {
    switch (recording, onAir) {
    case (true, true): return "\(camera.name) is recording and on air. Stopping the camera ends the take and its video output."
    case (true, false): return "\(camera.name) is recording. Stopping the camera ends the take."
    case (false, true): return "\(camera.name) is on air. Stopping the camera ends its video output."
    case (false, false): return "Stop \(camera.name)?"
    }
  }

  static func session(_ session: UISessionSnapshot) -> UISessionPresentation {
    let cameras = session.cameras.enumerated().map { camera($1, index: $0, in: session) }
    let recording = session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
    let longest = recording.map(\.recording.elapsed).max() ?? 0
    let elapsed = UIFormat.shortElapsed(longest)
    let anyRecordable = cameras.contains { $0.recordButtonEnabled }
    let recordControl: UIRecordControl
    if recording.count > 1 { recordControl = .stopAll(count: recording.count, elapsed: elapsed) }
    else if recording.count == 1 { recordControl = session.cameras.count > 1 ? .stopAll(count: 1, elapsed: elapsed) : .stop(elapsed: elapsed) }
    else { recordControl = .record(all: session.cameras.count > 1, enabled: anyRecordable) }

    let running = session.cameras.contains(where: \.running)
    let outputInUse: Bool
    let outputSummary: String
    switch session.outputMode {
    case .program:
      outputInUse = session.programInUse
      outputSummary = "Ultracam · Program · \(session.programInUse ? "in use" : "not in use")"
    case .separate:
      let inUse = session.cameras.filter(\.inUse)
      outputInUse = !inUse.isEmpty
      outputSummary = inUse.isEmpty ? "Virtual cameras not in use" : inUse.map { "Ultracam · \($0.name)" }.joined(separator: ", ") + " · in use"
    }

    let drivesLine = session.drives.compactMap { drive in drive.secondsLeft.map { "\(drive.name) \(UIFormat.duration($0))" } }
      .joined(separator: " · ")
    let recordingSummary: String
    if recording.isEmpty { recordingSummary = drivesLine.isEmpty ? "Not recording" : "Not recording · \(drivesLine) left" }
    else {
      let paused = recording.filter { $0.recording.status == .paused }.count
      let rolling = recording.count - paused
      let count = recording.count > 1 ? (paused > 0 ? "\(rolling) · paused \(paused) · " : "\(recording.count) · ") : (paused > 0 ? "paused · " : "")
      recordingSummary = "REC \(count)\(elapsed)" + (drivesLine.isEmpty ? "" : " · \(drivesLine) left")
    }

    var segments = [UIStatusSegment(kind: .output, text: outputSummary, tone: outputInUse ? .positive : .neutral)]
    if session.outputMode == .program {
      let onAir = session.cameras.first { $0.id == session.onAirID }?.name ?? "No camera"
      let mode = session.autoSwitching ? (session.autoHold ? "Auto · hold" : "Auto") : "Manual"
      segments.append(UIStatusSegment(kind: .program, text: "\(onAir) on air · \(mode)", tone: .neutral))
    }
    segments.append(UIStatusSegment(kind: .recording, text: recordingSummary, tone: recording.isEmpty ? .neutral : .critical))
    let live = session.cameras.filter(\.running)
    let withAudio = live.filter(\.audio.present)
    let audioText = live.isEmpty ? "Audio —" : live.count == 1 ? (withAudio.isEmpty ? "No embedded audio" : "Audio OK")
      : "Audio: \(withAudio.count) of \(live.count)"
    segments.append(UIStatusSegment(kind: .audio, text: audioText, tone: live.isEmpty || withAudio.count == live.count ? .neutral : .warning))
    if let warning = warning(session) { segments.append(UIStatusSegment(kind: .warning, text: warning, tone: .warning)) }

    let cutButtons = session.outputMode == .program ? cameras.map {
      UICutButton(id: $0.id, number: $0.number, name: $0.name, onAir: session.onAirID == $0.id,
        pending: session.pendingCutID == $0.id, enabled: $0.cutEnabled || session.onAirID == $0.id)
    } : []

    let title = session.outputMode == .program ? (session.programInUse ? "Meeting" : "Program")
      : (outputInUse ? "Meeting" : recording.isEmpty ? "Ultracam" : "Recording")
    var subtitleParts = [outputSummary]
    if !recording.isEmpty { subtitleParts.append("\(recording.count) recording") }

    return UISessionPresentation(
      title: title, subtitle: subtitleParts.joined(separator: " · "),
      cameras: cameras, selected: cameras.first(where: \.selected),
      outputMode: session.outputMode,
      layouts: UILayout.allCases.filter { session.outputMode == .program || $0 != .programView },
      layout: session.layout, recordControl: recordControl,
      camerasRunning: running,
      camerasControlTitle: session.cameras.count == 1 ? (running ? "Stop Camera" : "Start Camera") : (running ? "Stop Cameras" : "Start Cameras"),
      cutButtons: cutButtons, autoSwitching: session.autoSwitching,
      statusSegments: segments, outputSummary: outputSummary, outputInUse: outputInUse,
      recordingSummary: recordingSummary, menuBarIcon: menuBarIcon(session))
  }

  /// The single most important problem, if any, for the status bar and menu bar icon.
  static func warning(_ session: UISessionSnapshot) -> String? {
    for camera in session.cameras {
      if camera.recording.status == .recording, case .noSignal = camera.signal { return "\(camera.name): recording, no signal" }
      if camera.recording.failed || camera.recording.error != nil { return "\(camera.name): recording stopped" }
    }
    if let failed = session.cameras.first(where: \.automaticStartFailed) { return "\(failed.name): couldn't start" }
    if let low = session.drives.first(where: { ($0.secondsLeft ?? .infinity) < 30 * 60 }), let left = low.secondsLeft {
      return "\(low.name): \(UIFormat.duration(left)) left"
    }
    for camera in session.cameras where camera.running {
      switch camera.signal {
      case .noSignal: return "\(camera.name): no signal"
      case .unsupported: return "\(camera.name): unsupported format"
      case .deviceMissing: return "\(camera.name): input disconnected"
      default: break
      }
    }
    if let lut = session.cameras.first(where: { $0.lutError != nil }) { return "\(lut.name): LUT unavailable" }
    if session.outputMode == .program && session.programFormatMismatch { return "Program cameras use different formats" }
    return nil
  }

  static func menuBarIcon(_ session: UISessionSnapshot) -> UIMenuBarIcon {
    if warning(session) != nil { return .attention }
    if session.cameras.contains(where: { $0.recording.status == .recording }) { return .recording }
    let running = session.cameras.filter(\.running)
    guard !running.isEmpty else {
      return session.cameras.contains(where: \.automaticStart) ? .waiting : .stopped
    }
    let selected = running.first { $0.id == session.selectedID } ?? running[0]
    return selected.processing ? .live : .bypass
  }
}

import Foundation
import Observation
import CoreMedia
import CoreVideo

/// The codecs exposed by the recording UI. The media writer is injected through
/// `RecordingSessionDriver`, so this model does not own capture or file I/O.
enum RecordingCodec: String, CaseIterable, Codable, Equatable, Sendable {
  case proRes42210Bit
  case hevcMain10_422

  var title: String {
    switch self {
    case .proRes42210Bit: return "ProRes 422 10-bit"
    case .hevcMain10_422: return "HEVC Main10 4:2:2"
    }
  }

  var fileExtension: String {
    switch self {
    case .proRes42210Bit, .hevcMain10_422: return "mov"
    }
  }
}

enum RecordingTimecodeMode: String, CaseIterable, Codable, Equatable, Sendable {
  case source
  case recordStart
  case wallClock

  var title: String {
    switch self {
    case .source: return "Source timecode"
    case .recordStart: return "Record start"
    case .wallClock: return "Wall clock"
    }
  }
}

struct RecordingConfiguration: Equatable, Sendable {
  var codec: RecordingCodec = .proRes42210Bit
  var outputFolder: URL?
  var timecodeMode: RecordingTimecodeMode = .source

  init(codec: RecordingCodec = .proRes42210Bit, outputFolder: URL? = nil,
    timecodeMode: RecordingTimecodeMode = .source) {
    self.codec = codec
    self.outputFolder = outputFolder
    self.timecodeMode = timecodeMode
  }
}

struct RecordingFeedDescriptor: Identifiable, Hashable, Sendable {
  let id: FeedID
  var name: String

  init(id: FeedID, name: String) {
    self.id = id
    self.name = name
  }
}

enum RecordingStatus: String, Equatable, Sendable {
  case idle
  case recording
  case paused

  var title: String {
    switch self {
    case .idle: return "Idle"
    case .recording: return "Recording"
    case .paused: return "Paused"
    }
  }
}

struct RecordingFeedState: Identifiable, Equatable, Sendable {
  let id: FeedID
  var name: String
  var status: RecordingStatus = .idle
  var error: String?

  var isActive: Bool { status != .idle }
}

enum RecordingUIError: LocalizedError, Equatable {
  case unavailable
  case outputFolderRequired
  case rawAudioUnavailable
  case feedNotActive

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Recording is unavailable until a recording backend is connected."
    case .outputFolderRequired: return "Choose an output folder before recording."
    case .rawAudioUnavailable:
      return "Blackmagic raw audio recording is unavailable; video will be recorded without audio."
    case .feedNotActive:
      return "Start this feed before recording it. Only an active source feed can produce media."
    }
  }
}

/// The small boundary between controls and a future media writer.
/// Implementations are called on the main actor by `RecordingModel`.
protocol RecordingSessionDriver: AnyObject {
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws
  func pauseRecording(feedID: FeedID) throws
  func resumeRecording(feedID: FeedID) throws
  func stopRecording(feedID: FeedID) throws
}

/// Optional diagnostics exposed by a driver after a successful start. Keeping
/// this separate from `RecordingSessionDriver` preserves the small injected
/// test boundary and lets older drivers continue to work unchanged.
protocol RecordingSessionDriverDiagnostics: AnyObject {
  var startWarning: RecordingUIError? { get }
}

/// Native source recorder used by the app. Each feed owns one callback adapter
/// and one `SourceRecorderCore`, so pause/stop on one feed cannot affect any
/// other feed. Capture callbacks are connected only after the adapter starts.
final class NativeRecordingSessionDriver: RecordingSessionDriver, RecordingSessionDriverDiagnostics {
  typealias RecorderFactory = (SourceRecordingConfiguration) throws -> SourceRecorderCore

  private struct Session {
    let adapter: SourceRecordingCallbackAdapter
    let feedID: FeedID
  }

  private weak var capture: CaptureController?
  private let recorderFactory: RecorderFactory
  private let rawAudioCallbackAvailable: Bool
  private var sessions: [FeedID: Session] = [:]

  init(capture: CaptureController, rawAudioCallbackAvailable: Bool = false,
    recorderFactory: @escaping RecorderFactory = { try SourceRecorderCore(configuration: $0) }) {
    self.capture = capture
    self.rawAudioCallbackAvailable = rawAudioCallbackAvailable
    self.recorderFactory = recorderFactory
  }

  var startWarning: RecordingUIError? {
    rawAudioCallbackAvailable ? nil : .rawAudioUnavailable
  }

  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    guard let capture else {
      throw RecordingUIError.unavailable
    }
    guard !capture.hasActiveFeed || capture.isAccepting(feedID: feedID) else {
      throw RecordingUIError.feedNotActive
    }
    guard sessions[feedID] == nil else {
      throw SourceRecordingError.invalidState(.recording, operation: "start recording")
    }
    guard let folder = configuration.outputFolder else {
      throw RecordingUIError.outputFolderRequired
    }
    let outputURL = folder.appendingPathComponent(
      "ultrastudio-\(Self.safeComponent(feedID.rawValue))-\(UUID().uuidString).mov")
    let sourceConfiguration = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID(feedID.rawValue), outputURL: outputURL,
      width: 3840, height: 2160,
      videoCodec: configuration.codec == .proRes42210Bit
        ? kCMVideoCodecType_AppleProRes422HQ : kCMVideoCodecType_HEVC)
    let recorder = try recorderFactory(sourceConfiguration)
    let adapter = SourceRecordingCallbackAdapter(feedID: sourceConfiguration.feedID, recorder: recorder)
    try adapter.start()
    capture.setRecordingCallbacks(feedID: feedID, callbacks: adapter.callbacks)
    sessions[feedID] = Session(adapter: adapter, feedID: feedID)
  }

  func pauseRecording(feedID: FeedID) throws {
    guard let session = sessions[feedID] else {
      throw SourceRecordingError.invalidState(.idle, operation: "pause recording")
    }
    try session.adapter.pause()
  }

  func resumeRecording(feedID: FeedID) throws {
    guard let session = sessions[feedID] else {
      throw SourceRecordingError.invalidState(.idle, operation: "resume recording")
    }
    try session.adapter.resume()
  }

  func stopRecording(feedID: FeedID) throws {
    guard let session = sessions[feedID] else { return }
    capture?.setRecordingCallbacks(feedID: feedID, callbacks: nil)
    do {
      try session.adapter.stop()
      sessions.removeValue(forKey: feedID)
    } catch {
      capture?.setRecordingCallbacks(feedID: feedID, callbacks: session.adapter.callbacks)
      throw error
    }
  }

  /// Callers must not fabricate an audio sample when a backend has no raw PCM
  /// callback; this explicit error keeps unsupported capture visible.
  func appendRawAudio(feedID: FeedID, sample: CMSampleBuffer) throws {
    guard rawAudioCallbackAvailable else { throw RecordingUIError.rawAudioUnavailable }
    guard let session = sessions[feedID] else {
      throw SourceRecordingError.invalidState(.idle, operation: "append audio")
    }
    guard session.adapter.appendEmbeddedAudio(sample: sample) else {
      throw SourceRecordingError.unsupportedSample("The raw audio sample was rejected.")
    }
  }

  private static func safeComponent(_ value: String) -> String {
    let result = value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return result.isEmpty ? "feed" : result
  }
}

final class UnavailableRecordingSessionDriver: RecordingSessionDriver {
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    throw RecordingUIError.unavailable
  }

  func pauseRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
  func resumeRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
  func stopRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
}

@MainActor @Observable
final class RecordingModel {
  var codec: RecordingCodec = .proRes42210Bit
  var outputFolder: URL?
  var timecodeMode: RecordingTimecodeMode = .source
  private(set) var feeds: [RecordingFeedState] = []

  private let driver: RecordingSessionDriver

  init(feeds: [RecordingFeedDescriptor] = [], driver: RecordingSessionDriver = UnavailableRecordingSessionDriver()) {
    self.driver = driver
    updateFeeds(feeds)
  }

  var configuration: RecordingConfiguration {
    RecordingConfiguration(codec: codec, outputFolder: outputFolder, timecodeMode: timecodeMode)
  }

  var canRecordAny: Bool {
    outputFolder != nil && feeds.contains { $0.status == .idle }
  }

  var canPauseAny: Bool { feeds.contains { $0.status == .recording } }
  var canStopAny: Bool { feeds.contains { $0.status != .idle } }

  /// Replace descriptors when the feed coordinator changes while retaining
  /// active state and errors for feeds that still exist.
  func updateFeeds(_ descriptors: [RecordingFeedDescriptor]) {
    let old = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
    feeds = descriptors.map { descriptor in
      var state = old[descriptor.id] ?? RecordingFeedState(id: descriptor.id, name: descriptor.name)
      state.name = descriptor.name
      return state
    }
  }

  func record(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .idle else { return }
    guard outputFolder != nil else {
      feeds[index].error = RecordingUIError.outputFolderRequired.localizedDescription
      return
    }
    do {
      try driver.startRecording(feedID: feedID, configuration: configuration)
      feeds[index].status = .recording
      feeds[index].error = (driver as? RecordingSessionDriverDiagnostics)?.startWarning?.localizedDescription
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func pause(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .recording else { return }
    do {
      try driver.pauseRecording(feedID: feedID)
      feeds[index].status = .paused
      feeds[index].error = nil
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func resume(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .paused else { return }
    do {
      try driver.resumeRecording(feedID: feedID)
      feeds[index].status = .recording
      feeds[index].error = nil
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func stop(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status != .idle else { return }
    do {
      try driver.stopRecording(feedID: feedID)
      feeds[index].status = .idle
      feeds[index].error = nil
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func recordAll() {
    for id in feeds.map(\.id) { record(feedID: id) }
  }

  func pauseAll() {
    for id in feeds.map(\.id) { pause(feedID: id) }
  }

  func stopAll() {
    for id in feeds.map(\.id) { stop(feedID: id) }
  }

  private func index(of id: FeedID) -> Int? {
    feeds.firstIndex { $0.id == id }
  }
}

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

protocol RecordingSessionDriverArtifacts: AnyObject {
  func recordingOutputURL(feedID: FeedID) -> URL?
}

/// Native source recorder used by the app. Each feed owns one callback adapter
/// and one `SourceRecorderCore`, so pause/stop on one feed cannot affect any
/// other feed. Capture callbacks are connected only after the adapter starts.
final class NativeRecordingSessionDriver: RecordingSessionDriver, RecordingSessionDriverDiagnostics,
  RecordingSessionDriverArtifacts {
  typealias RecorderFactory = (SourceRecordingConfiguration) throws -> SourceRecorderCore

  private struct Session {
    let adapter: SourceRecordingCallbackAdapter
    let feedID: FeedID
    /// The AVAssetWriter writes into this session's temporary path. Keeping
    /// the owner here guarantees that its reservation survives until the
    /// writer is finalized or cancelled.
    let output: RecordingOutputSession
  }

  private let captureForFeed: (FeedID) -> CaptureController
  private let recorderFactory: RecorderFactory
  private let rawAudioCallbackAvailable: Bool
  // Capture callbacks may arrive off the main actor while the recording
  // controls start/stop sessions on it. Keep the catalog and the output
  // reservations behind one lock so a callback can never race a session
  // teardown. Managers are shared by folder/extension so disk reservations
  // account for all feeds recording to the same volume.
  private let sessionLock = NSLock()
  private var sessions: [FeedID: Session] = [:]
  private var outputManagers: [String: RecordingOutputManager] = [:]

  init(capture: CaptureController, rawAudioCallbackAvailable: Bool = false,
    captureForFeed: ((FeedID) -> CaptureController)? = nil,
    recorderFactory: @escaping RecorderFactory = { try SourceRecorderCore(configuration: $0) }) {
    self.captureForFeed = captureForFeed ?? { _ in capture }
    self.rawAudioCallbackAvailable = rawAudioCallbackAvailable
    self.recorderFactory = recorderFactory
  }

  var startWarning: RecordingUIError? {
    rawAudioCallbackAvailable ? nil : .rawAudioUnavailable
  }

  func recordingOutputURL(feedID: FeedID) -> URL? {
    sessionLock.withLock { sessions[feedID]?.output.finalURL }
  }

  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    let capture = captureForFeed(feedID)
    guard !capture.hasActiveFeed || capture.isAccepting(feedID: feedID) else {
      throw RecordingUIError.feedNotActive
    }
    guard sessionLock.withLock({ sessions[feedID] == nil }) else {
      throw SourceRecordingError.invalidState(.recording, operation: "start recording")
    }
    guard let folder = configuration.outputFolder else {
      throw RecordingUIError.outputFolderRequired
    }
    // Allocate a per-feed atomic output before creating the writer. The
    // writer only sees the temporary path; a completed session is renamed to
    // its final path after all queued samples have drained.
    let outputManager = try manager(for: folder, fileExtension: configuration.codec.fileExtension)
    let output = try outputManager.beginExternalWriterSession(
      feedID: Self.safeComponent(feedID.rawValue))
    do {
      let sourceConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID(feedID.rawValue), outputURL: output.temporaryURL,
        width: 3840, height: 2160,
        videoCodec: configuration.codec == .proRes42210Bit
          ? kCMVideoCodecType_AppleProRes422HQ : kCMVideoCodecType_HEVC,
        timecodePolicy: Self.timecodePolicy(for: configuration.timecodeMode))
      let recorder = try recorderFactory(sourceConfiguration)
      let adapter = SourceRecordingCallbackAdapter(feedID: sourceConfiguration.feedID, recorder: recorder)
      try adapter.start()
      sessionLock.lock()
      // A concurrent start for the same feed may have won while the writer
      // was being constructed. Never overwrite that live session or leak its
      // output reservation.
      let available = sessions[feedID] == nil
      if available {
        sessions[feedID] = Session(adapter: adapter, feedID: feedID, output: output)
      }
      sessionLock.unlock()
      guard available else {
        throw SourceRecordingError.invalidState(.recording, operation: "start recording")
      }
      // Install the callback only after winning the session slot. Otherwise a
      // losing concurrent start could replace the active recorder's callback
      // and leave the winning session unable to receive media.
      capture.setRecordingCallbacks(feedID: feedID, callbacks: adapter.callbacks)
    } catch {
      try? output.cancel()
      throw error
    }
  }

  func pauseRecording(feedID: FeedID) throws {
    guard let session = sessionLock.withLock({ sessions[feedID] }) else {
      throw SourceRecordingError.invalidState(.idle, operation: "pause recording")
    }
    try session.adapter.pause()
    do {
      try session.output.pause()
    } catch {
      // Keep the recorder usable if the filesystem pause operation fails.
      try? session.adapter.resume()
      throw error
    }
  }

  func resumeRecording(feedID: FeedID) throws {
    guard let session = sessionLock.withLock({ sessions[feedID] }) else {
      throw SourceRecordingError.invalidState(.idle, operation: "resume recording")
    }
    try session.output.resume()
    do {
      try session.adapter.resume()
    } catch {
      try? session.output.pause()
      throw error
    }
  }

  func stopRecording(feedID: FeedID) throws {
    guard let session = sessionLock.withLock({ sessions[feedID] }) else { return }
    captureForFeed(feedID).setRecordingCallbacks(feedID: feedID, callbacks: nil)
    do {
      try session.adapter.stop()
      let telemetry = session.adapter.telemetry
      // A writer that never received source media must not leave a misleading
      // zero-byte movie in the user's catalog. Cancel removes the temporary
      // file and releases the reservation.
      if telemetry.appendedVideo == 0 && telemetry.appendedAudio == 0 {
        try session.output.cancel()
      } else if session.adapter.state == .failed {
        try session.output.cancel()
      } else {
        _ = try session.output.finish()
      }
      _ = sessionLock.withLock { sessions.removeValue(forKey: feedID) }
    } catch {
      try? session.output.cancel()
      // A failed adapter has already drained/invalidated its writer. Keeping
      // that dead session in the catalog would leave a cancelled output
      // reservation reachable only through a retry that can never succeed.
      // Remove it and leave the UI state/error for the caller to surface;
      // a subsequent stop then cleanly clears the model's active state.
      _ = sessionLock.withLock { sessions.removeValue(forKey: feedID) }
      throw error
    }
  }

  /// Callers must not fabricate an audio sample when a backend has no raw PCM
  /// callback; this explicit error keeps unsupported capture visible.
  func appendRawAudio(feedID: FeedID, sample: CMSampleBuffer) throws {
    guard rawAudioCallbackAvailable else { throw RecordingUIError.rawAudioUnavailable }
    guard let session = sessionLock.withLock({ sessions[feedID] }) else {
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

  private func manager(for folder: URL, fileExtension: String) throws -> RecordingOutputManager {
    let root = folder.standardizedFileURL.resolvingSymlinksInPath()
    let key = "\(root.path)\u{0}\(fileExtension.lowercased())"
    sessionLock.lock()
    defer { sessionLock.unlock() }
    if let existing = outputManagers[key] { return existing }
    let manager = try RecordingOutputManager(rootDirectory: root, fileExtension: fileExtension)
    outputManagers[key] = manager
    return manager
  }

  private static func timecodePolicy(for mode: RecordingTimecodeMode) -> RecordingTimecodePolicy {
    switch mode {
    case .source: return .source
    case .recordStart: return .recordStart
    case .wallClock: return .wallClock
    }
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
  var outputFolder: URL? { didSet { onOutputFolderChanged?(outputFolder) } }
  var timecodeMode: RecordingTimecodeMode = .source
  private(set) var feeds: [RecordingFeedState] = []

  var onOutputFolderChanged: ((URL?) -> Void)?
  var onRecordingStarted: ((FeedID, URL) -> Void)?
  var onRecordingFinished: ((FeedID, URL?) -> Void)?

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
  /// active state and errors for feeds that still exist. Keep an active state
  /// for a descriptor that disappeared until its recording is stopped; this
  /// prevents an in-flight session from becoming unreachable (and leaking its
  /// writer/output reservation) when a feed list refresh races recording.
  func updateFeeds(_ descriptors: [RecordingFeedDescriptor]) {
    // Feed discovery can briefly publish duplicate descriptors while a route
    // is being rebuilt. Building a dictionary with `uniqueKeysWithValues:`
    // would trap on that transient state and take down the recording UI.
    var old: [FeedID: RecordingFeedState] = [:]
    for state in feeds { old[state.id] = state }
    var seen = Set<FeedID>()
    feeds = descriptors.compactMap { descriptor in
      guard seen.insert(descriptor.id).inserted else { return nil }
      var state = old[descriptor.id] ?? RecordingFeedState(id: descriptor.id, name: descriptor.name)
      state.name = descriptor.name
      return state
    }
    let retainedIDs = Set(descriptors.map(\.id))
    feeds.append(contentsOf: old.values
      .filter { $0.isActive && !retainedIDs.contains($0.id) }
      .sorted { $0.id.rawValue < $1.id.rawValue })
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
      if let output = (driver as? RecordingSessionDriverArtifacts)?.recordingOutputURL(feedID: feedID) {
        onRecordingStarted?(feedID, output)
      }
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
      let output = (driver as? RecordingSessionDriverArtifacts)?.recordingOutputURL(feedID: feedID)
      try driver.stopRecording(feedID: feedID)
      feeds[index].status = .idle
      feeds[index].error = nil
      let finalOutput = output.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      onRecordingFinished?(feedID, finalOutput)
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

import Foundation
import Observation

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

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Recording is unavailable until a recording backend is connected."
    case .outputFolderRequired: return "Choose an output folder before recording."
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
      feeds[index].error = nil
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

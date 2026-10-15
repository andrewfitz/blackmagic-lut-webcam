import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Identifies one source feed in the recording catalog. A recorder instance owns
/// exactly one output file for this feed.
struct SourceRecordingFeedID: Hashable, Codable, Sendable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  var description: String { rawValue }
}

enum SourceRecordingState: Equatable, Sendable {
  case idle
  case recording
  case paused
  case stopping
  case finished
  case failed
}

enum SourceRecordingDropReason: String, Equatable, Sendable {
  case queueFull
  case paused
  case notRecording
  case invalidSample
  case writerNotReady
  case appendFailure
}

/// The recorder accepts the capture callback's original CMSampleBuffer. No
/// Core Image, Metal, pixel-buffer conversion, or color transform is performed
/// by this layer.
struct SourceRecordingConfiguration {
  let feedID: SourceRecordingFeedID
  let outputURL: URL
  let width: Int
  let height: Int
  let videoCodec: CMVideoCodecType
  let fileType: AVFileType
  let queueCapacity: Int
  let realTimeEncoding: Bool
  let maxKeyFrameInterval: Int

  init(feedID: SourceRecordingFeedID, outputURL: URL, width: Int, height: Int,
    videoCodec: CMVideoCodecType = kCMVideoCodecType_HEVC,
    fileType: AVFileType = .mov, queueCapacity: Int = 12,
    realTimeEncoding: Bool = true, maxKeyFrameInterval: Int = 60) throws {
    guard !feedID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SourceRecordingError.invalidConfiguration("A feed ID is required.")
    }
    guard width > 0, height > 0 else {
      throw SourceRecordingError.invalidConfiguration("Video dimensions must be positive.")
    }
    guard queueCapacity > 0 else {
      throw SourceRecordingError.invalidConfiguration("Queue capacity must be positive.")
    }
    guard maxKeyFrameInterval > 0 else {
      throw SourceRecordingError.invalidConfiguration("Key-frame interval must be positive.")
    }
    guard outputURL.isFileURL else {
      throw SourceRecordingError.invalidConfiguration("The recording destination must be a file URL.")
    }
    self.feedID = feedID
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.videoCodec = videoCodec
    self.fileType = fileType
    self.queueCapacity = queueCapacity
    self.realTimeEncoding = realTimeEncoding
    self.maxKeyFrameInterval = maxKeyFrameInterval
  }
}

struct SourceRecordingTelemetry: Equatable, Sendable {
  fileprivate(set) var state: SourceRecordingState = .idle
  fileprivate(set) var enqueuedVideo: UInt64 = 0
  fileprivate(set) var enqueuedAudio: UInt64 = 0
  fileprivate(set) var appendedVideo: UInt64 = 0
  fileprivate(set) var appendedAudio: UInt64 = 0
  fileprivate(set) var droppedQueueFull: UInt64 = 0
  fileprivate(set) var droppedPaused: UInt64 = 0
  fileprivate(set) var droppedNotRecording: UInt64 = 0
  fileprivate(set) var droppedInvalidSample: UInt64 = 0
  fileprivate(set) var droppedWriterNotReady: UInt64 = 0
  fileprivate(set) var droppedAppendFailure: UInt64 = 0
  fileprivate(set) var writerErrors: UInt64 = 0
  fileprivate(set) var encodedVideo: UInt64 = 0
  fileprivate(set) var droppedEncodedVideo: UInt64 = 0
  fileprivate(set) var encoderErrors: UInt64 = 0
  fileprivate(set) var lastError: String?

  var totalDrops: UInt64 {
    droppedQueueFull + droppedPaused + droppedNotRecording + droppedInvalidSample +
      droppedWriterNotReady + droppedAppendFailure
  }
}

enum SourceRecordingError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(String)
  case invalidState(SourceRecordingState, operation: String)
  case writerFailure(String)
  case writerNotReady(String)
  case unsupportedSample(String)

  var errorDescription: String? {
    switch self {
    case let .invalidConfiguration(message): return "Invalid recording configuration: \(message)"
    case let .invalidState(state, operation): return "Cannot \(operation) while recorder is \(state)."
    case let .writerFailure(message): return "Recording writer failed: \(message)"
    case let .writerNotReady(message): return "Recording writer is not ready: \(message)"
    case let .unsupportedSample(message): return "Unsupported recording sample: \(message)"
    }
  }
}

/// A testable boundary around AVAssetWriter. Implementations must preserve the
/// source sample timing and must not mutate or replace the source buffers.
struct SourceRecordingWriterTelemetry: Equatable, Sendable {
  var encodedVideo: UInt64 = 0
  var droppedEncodedVideo: UInt64 = 0
  var encoderErrors: UInt64 = 0
  var lastError: String?
}

protocol SourceRecordingWriter: AnyObject {
  var telemetry: SourceRecordingWriterTelemetry { get }
  func start() throws
  func appendVideo(_ sample: CMSampleBuffer) throws
  func appendAudio(_ sample: CMSampleBuffer) throws
  func finish() throws
}

extension SourceRecordingWriter {
  var telemetry: SourceRecordingWriterTelemetry { SourceRecordingWriterTelemetry() }
}

/// Queue-confined recording controller. Callback callers only perform bounded
/// admission work; writing and VideoToolbox encoding happen on the private
/// serial queue. One instance maps to one feed and one output file.
final class SourceRecorderCore: @unchecked Sendable {
  typealias WriterFactory = () throws -> SourceRecordingWriter

  private enum SampleKind {
    case video
    case audio
  }

  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private let configuration: SourceRecordingConfiguration
  private let writer: SourceRecordingWriter
  private var telemetryValue = SourceRecordingTelemetry()
  private var pending = 0

  init(configuration: SourceRecordingConfiguration, writerFactory: @escaping WriterFactory) throws {
    self.configuration = configuration
    self.writer = try writerFactory()
    self.queue = DispatchQueue(label: "org.ultrastudiolut.recording.\(configuration.feedID.rawValue)",
      qos: .userInitiated)
  }

  convenience init(configuration: SourceRecordingConfiguration) throws {
    try self.init(configuration: configuration, writerFactory: {
      try AVAssetSourceRecordingWriter(configuration: configuration)
    })
  }

  var state: SourceRecordingState { stateLock.withLock { telemetryValue.state } }
  var telemetry: SourceRecordingTelemetry {
    let writerSnapshot = writer.telemetry
    return stateLock.withLock {
      var snapshot = telemetryValue
      snapshot.encodedVideo = writerSnapshot.encodedVideo
      snapshot.droppedEncodedVideo = writerSnapshot.droppedEncodedVideo
      snapshot.encoderErrors = writerSnapshot.encoderErrors
      if snapshot.lastError == nil { snapshot.lastError = writerSnapshot.lastError }
      return snapshot
    }
  }

  func start() throws {
    try queue.sync {
      let current = stateLock.withLock { telemetryValue.state }
      guard current == .idle else {
        throw SourceRecordingError.invalidState(current, operation: "start")
      }
      do {
        try writer.start()
        stateLock.withLock { telemetryValue.state = .recording }
      } catch {
        let failure = Self.recordingError(error)
        stateLock.withLock {
          telemetryValue.state = .failed
          telemetryValue.writerErrors &+= 1
          telemetryValue.lastError = failure.localizedDescription
        }
        throw failure
      }
    }
  }

  @discardableResult
  func appendVideo(_ sample: CMSampleBuffer) -> Bool {
    enqueue(sample, kind: .video)
  }

  @discardableResult
  func appendAudio(_ sample: CMSampleBuffer) -> Bool {
    enqueue(sample, kind: .audio)
  }

  func pause() throws {
    try stateLock.withLock {
      guard telemetryValue.state == .recording else {
        throw SourceRecordingError.invalidState(telemetryValue.state, operation: "pause")
      }
      telemetryValue.state = .paused
    }
  }

  func resume() throws {
    try stateLock.withLock {
      guard telemetryValue.state == .paused else {
        throw SourceRecordingError.invalidState(telemetryValue.state, operation: "resume")
      }
      telemetryValue.state = .recording
    }
  }

  /// Drains already admitted samples before finalizing the writer. New callback
  /// samples are rejected once stopping begins. This method must not be called
  /// from the recorder's private queue or from a writer callback.
  func stop() throws {
    let shouldStop = stateLock.withLock { () -> Bool in
      switch telemetryValue.state {
      case .recording, .paused:
        telemetryValue.state = .stopping
        return true
      case .idle:
        return false
      case .finished:
        return false
      case .failed:
        return false
      case .stopping:
        return false
      }
    }
    guard shouldStop else {
      let current = stateLock.withLock { telemetryValue.state }
      if current == .idle || current == .finished { return }
      if current == .failed { throw SourceRecordingError.invalidState(current, operation: "stop") }
      return
    }
    try queue.sync {
      do {
        try writer.finish()
        stateLock.withLock { telemetryValue.state = .finished }
      } catch {
        let failure = Self.recordingError(error)
        stateLock.withLock {
          telemetryValue.state = .failed
          telemetryValue.writerErrors &+= 1
          telemetryValue.lastError = failure.localizedDescription
        }
        throw failure
      }
    }
  }

  private func enqueue(_ sample: CMSampleBuffer, kind: SampleKind) -> Bool {
    guard Self.isReady(sample, kind: kind) else {
      recordDrop(.invalidSample)
      return false
    }
    let admitted = stateLock.withLock { () -> Bool in
      guard telemetryValue.state == .recording else {
        switch telemetryValue.state {
        case .paused: telemetryValue.droppedPaused &+= 1
        case .idle, .finished, .failed, .stopping: telemetryValue.droppedNotRecording &+= 1
        case .recording: break
        }
        return false
      }
      guard pending < configuration.queueCapacity else {
        telemetryValue.droppedQueueFull &+= 1
        return false
      }
      pending += 1
      switch kind {
      case .video: telemetryValue.enqueuedVideo &+= 1
      case .audio: telemetryValue.enqueuedAudio &+= 1
      }
      return true
    }
    guard admitted else { return false }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.stateLock.withLock { self.pending -= 1 } }
      do {
        switch kind {
        case .video:
          try self.writer.appendVideo(sample)
          self.stateLock.withLock { self.telemetryValue.appendedVideo &+= 1 }
        case .audio:
          try self.writer.appendAudio(sample)
          self.stateLock.withLock { self.telemetryValue.appendedAudio &+= 1 }
        }
      } catch {
        let failure = Self.recordingError(error)
        self.stateLock.withLock {
          if case .writerNotReady = failure {
            self.telemetryValue.droppedWriterNotReady &+= 1
            self.telemetryValue.lastError = failure.localizedDescription
          } else {
            self.telemetryValue.droppedAppendFailure &+= 1
            self.telemetryValue.writerErrors &+= 1
            self.telemetryValue.lastError = failure.localizedDescription
            self.telemetryValue.state = .failed
          }
        }
      }
    }
    return true
  }

  private func recordDrop(_ reason: SourceRecordingDropReason) {
    stateLock.withLock {
      switch reason {
      case .invalidSample: telemetryValue.droppedInvalidSample &+= 1
      case .queueFull: telemetryValue.droppedQueueFull &+= 1
      case .paused: telemetryValue.droppedPaused &+= 1
      case .notRecording: telemetryValue.droppedNotRecording &+= 1
      case .writerNotReady: telemetryValue.droppedWriterNotReady &+= 1
      case .appendFailure: telemetryValue.droppedAppendFailure &+= 1
      }
    }
  }

  private static func isReady(_ sample: CMSampleBuffer, kind: SampleKind) -> Bool {
    guard CMSampleBufferDataIsReady(sample) else { return false }
    switch kind {
    case .video:
      return CMSampleBufferGetImageBuffer(sample) != nil &&
        CMSampleBufferGetFormatDescription(sample) != nil
    case .audio:
      return CMSampleBufferGetFormatDescription(sample) != nil &&
        CMSampleBufferGetNumSamples(sample) > 0
    }
  }

  private static func recordingError(_ error: Error) -> SourceRecordingError {
    if let error = error as? SourceRecordingError { return error }
    return .writerFailure(error.localizedDescription)
  }
}

/// Product-facing name for the per-feed source recorder. The typealias keeps
/// the queue and writer contracts available to synthetic tests without pulling
/// capture or UI dependencies into this module.
typealias DirectSourceRecorder = SourceRecorderCore

import CoreMedia
import CoreVideo
import XCTest

/// Synthetic recorder coverage for two feeds. The fake writers avoid touching
/// disk or invoking VideoToolbox while preserving SourceRecorderCore's queue,
/// state and telemetry boundaries.
@objcMembers final class MulticamRuntimeChecks: XCTestCase {
  func testFeedRecordersPauseAndStopIndependently() throws {
    let writerA = RecordingWriterProbe()
    let writerB = RecordingWriterProbe()
    let recorderA = try SourceRecorderCore(
      configuration: configuration(for: "feed-a"), writerFactory: { writerA })
    let recorderB = try SourceRecorderCore(
      configuration: configuration(for: "feed-b"), writerFactory: { writerB })

    // Starting both sessions models two independent feed outputs.
    try recorderA.start()
    try recorderB.start()
    XCTAssertEqual(recorderA.state, .recording)
    XCTAssertEqual(recorderB.state, .recording)
    XCTAssertTrue(recorderA.appendVideo(try sample(at: CMTime(value: 1, timescale: 60))))
    XCTAssertTrue(recorderB.appendVideo(try sample(at: CMTime(value: 1, timescale: 60))))

    // Pausing A must reject only A's callback while B continues to admit media.
    try recorderA.pause()
    XCTAssertEqual(recorderA.state, .paused)
    XCTAssertEqual(recorderB.state, .recording)
    XCTAssertFalse(recorderA.appendVideo(try sample(at: CMTime(value: 2, timescale: 60))))
    XCTAssertTrue(recorderB.appendVideo(try sample(at: CMTime(value: 2, timescale: 60))))
    XCTAssertEqual(recorderA.telemetry.droppedPaused, 1)
    XCTAssertEqual(recorderB.telemetry.droppedPaused, 0)

    // B can finish while A is paused. Resuming A starts a new admitted segment
    // without changing B's finished state or telemetry.
    try recorderB.stop()
    XCTAssertEqual(recorderB.state, .finished)
    XCTAssertEqual(recorderA.state, .paused)
    XCTAssertEqual(writerB.starts, 1)
    XCTAssertEqual(writerB.finishes, 1)
    XCTAssertEqual(recorderB.telemetry.enqueuedVideo, 2)

    try recorderA.resume()
    XCTAssertEqual(recorderA.state, .recording)
    XCTAssertTrue(recorderA.appendVideo(try sample(at: CMTime(value: 3, timescale: 60))))
    try recorderA.stop()
    XCTAssertEqual(recorderA.state, .finished)
    XCTAssertEqual(writerA.starts, 1)
    XCTAssertEqual(writerA.finishes, 1)
    XCTAssertEqual(recorderA.telemetry.enqueuedVideo, 2)
    XCTAssertEqual(recorderA.telemetry.droppedNotRecording, 0)
  }

  func testStoppingOneFeedDoesNotDrainTheOtherRecorderQueue() throws {
    let writerA = RecordingWriterProbe()
    let writerB = RecordingWriterProbe()
    let recorderA = try SourceRecorderCore(
      configuration: configuration(for: "feed-a"), writerFactory: { writerA })
    let recorderB = try SourceRecorderCore(
      configuration: configuration(for: "feed-b"), writerFactory: { writerB })
    try recorderA.start()
    try recorderB.start()

    // Each recorder owns a private queue. Finishing B must not drain or finish
    // A's admitted callback.
    XCTAssertTrue(recorderA.appendVideo(try sample(at: CMTime(value: 1, timescale: 60))))
    XCTAssertTrue(recorderB.appendVideo(try sample(at: CMTime(value: 1, timescale: 60))))
    try recorderB.stop()
    XCTAssertEqual(recorderB.state, .finished)
    XCTAssertEqual(writerB.finishes, 1)
    XCTAssertEqual(recorderA.state, .recording)
    XCTAssertEqual(writerA.finishes, 0)

    try recorderA.stop()
    XCTAssertEqual(recorderA.state, .finished)
    XCTAssertEqual(writerA.finishes, 1)
    XCTAssertEqual(recorderA.telemetry.appendedVideo, 1)
  }

  private func configuration(for feedID: String) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feedID),
      outputURL: URL(fileURLWithPath: "/tmp/ultrastudio-lut-\(feedID).mov"),
      width: 2, height: 2, queueCapacity: 2)
  }

  private func sample(at time: CMTime) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image else {
      throw VideoError.message("Synthetic recording frame allocation failed.")
    }
    return try VideoContract.sample(image, at: time, duration: VideoContract.fastDuration)
  }
}

private final class RecordingWriterProbe: SourceRecordingWriter {
  var starts = 0
  var finishes = 0
  var appendedVideo = 0
  private let lock = NSLock()

  func start() throws {
    lock.withLock { starts += 1 }
  }

  func appendVideo(_ sample: CMSampleBuffer) throws {
    lock.withLock {
      appendedVideo += 1
    }
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {}

  func finish() throws {
    lock.withLock { finishes += 1 }
  }
}

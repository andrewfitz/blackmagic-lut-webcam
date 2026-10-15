import CoreMedia
import Foundation
import XCTest

private final class FixedDiskSpace: @unchecked Sendable, RecordingDiskSpaceProvider {
  var bytes: Int64
  init(_ bytes: Int64) { self.bytes = bytes }
  func availableBytes(at directory: URL) throws -> Int64 { bytes }
}

private final class MemorySegmentWriter: RecordingSegmentWriter {
  struct Segment {
    let index: Int
    let start: CMTime
    var packets: [NormalizedRecordingPacket]
    var end: CMTime?
  }

  var segments: [Segment] = []
  var activeIndex: Int?
  var failAppend = false

  func beginSegment(index: Int, startTime: CMTime) throws {
    guard activeIndex == nil else { throw RecordingError.invalidState }
    segments.append(Segment(index: index, start: startTime, packets: [], end: nil))
    activeIndex = segments.count - 1
  }

  func append(_ packet: NormalizedRecordingPacket) throws {
    guard let activeIndex else { throw RecordingError.invalidState }
    if failAppend { throw RecordingError.writer("synthetic append failure") }
    segments[activeIndex].packets.append(packet)
  }

  func finalizeSegment(endTime: CMTime) throws -> RecordingSegmentInfo {
    guard let activeIndex else { throw RecordingError.invalidState }
    segments[activeIndex].end = endTime
    let segment = segments[activeIndex]
    self.activeIndex = nil
    return RecordingSegmentInfo(index: segment.index, startTime: segment.start,
      endTime: endTime)
  }

  func abortSegment() { activeIndex = nil }
}

private func assertEnqueued(_ result: Result<Void, RecordingError>,
                            file: StaticString = #filePath, line: UInt = #line) {
  guard case .success = result else {
    XCTFail("Expected packet admission, got \(result)", file: file, line: line)
    return
  }
}

@objcMembers final class RecordingChecks: XCTestCase {
  func testNormalizerRemainsMonotonicAcrossLargePacketCount() {
    var normalizer = RecordingTimestampNormalizer(timescale: 60_000)
    for index in 0..<100_000 {
      let packet = RecordingPacket(mediaKind: .video,
        presentationTime: CMTime(value: Int64(index) * 2_002, timescale: 60_000),
        duration: CMTime(value: 2_002, timescale: 60_000))
      if case .failure(let error) = normalizer.normalize(packet) {
        XCTFail("packet \(index) rejected: \(error)")
      }
    }
    let backwards = RecordingPacket(mediaKind: .video,
      presentationTime: CMTime(value: 1, timescale: 60_000),
      duration: CMTime(value: 2_002, timescale: 60_000))
    guard case .failure(.timestampRegressed) = normalizer.normalize(backwards) else {
      return XCTFail("Backwards timestamp must be rejected")
    }
  }

  func testDriftBoundFailsWithoutDroppingTheOffendingPacket() throws {
    var tracker = RecordingAVDriftTracker(maximumDrift: CMTime(value: 1, timescale: 10))
    let video = RecordingPacket(mediaKind: .video, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30))
    let audio = RecordingPacket(mediaKind: .audio, presentationTime: CMTime(value: 1, timescale: 5),
      duration: CMTime(value: 1, timescale: 48_000))
    var videoNormalizer = RecordingTimestampNormalizer()
    var audioNormalizer = RecordingTimestampNormalizer()
    let videoResult = try XCTUnwrap(videoNormalizer.normalize(video).successValue)
    _ = try tracker.observe(videoResult)
    let audioResult = try XCTUnwrap(audioNormalizer.normalize(audio).successValue)
    XCTAssertThrowsError(try tracker.observe(audioResult)) { error in
      guard case .exceedsLimit = error as? RecordingDriftError else {
        return XCTFail("Expected a bounded A/V drift failure, got \(error)")
      }
    }
  }

  func testQueueRejectsOverflowInsteadOfDropping() throws {
    let queue = try BoundedRecordingQueue<Int>(capacity: 2)
    XCTAssertNoThrow(try queue.enqueue(1))
    XCTAssertNoThrow(try queue.enqueue(2))
    XCTAssertThrowsError(try queue.enqueue(3)) { error in
      XCTAssertEqual(error as? RecordingQueueError, .full)
    }
    XCTAssertEqual(queue.dequeue(), 1)
    XCTAssertEqual(queue.dequeue(), 2)
    XCTAssertNil(queue.dequeue())
  }

  func testSessionRollsOverAndPauseResumeKeepsTimelineContinuous() throws {
    let writer = MemorySegmentWriter()
    let config = LongRunRecordingConfiguration(timescale: 1_000,
      maximumSegmentDuration: CMTime(value: 1_000, timescale: 1_000),
      maximumAVDrift: CMTime(value: 1, timescale: 1), queueCapacity: 8,
      minimumFreeBytes: 0, outputDirectory: URL(fileURLWithPath: "/tmp/ultrastudio-recording-test"))
    let session = try LongRunRecordingSession(configuration: config,
      diskSpace: FixedDiskSpace(Int64.max), writer: writer)
    try session.start()
    for time in [0, 500, 1_000] {
      let pts = CMTime(value: Int64(time), timescale: 1_000)
      assertEnqueued(session.enqueue(RecordingPacket(mediaKind: .video, presentationTime: pts,
        duration: CMTime(value: 500, timescale: 1_000))))
      assertEnqueued(session.enqueue(RecordingPacket(mediaKind: .audio, presentationTime: pts,
        duration: CMTime(value: 500, timescale: 1_000))))
      try session.drain()
    }
    XCTAssertEqual(writer.segments.count, 2)
    try session.pause()
    guard case .failure(.paused) = session.enqueue(RecordingPacket(mediaKind: .video,
      presentationTime: CMTime(value: 100_000, timescale: 1_000),
      duration: CMTime(value: 500, timescale: 1_000))) else {
      return XCTFail("Packets admitted while paused must be rejected")
    }
    try session.resume()
    let resumed = CMTime(value: 100_000, timescale: 1_000)
    assertEnqueued(session.enqueue(RecordingPacket(mediaKind: .video,
      presentationTime: resumed, duration: CMTime(value: 500, timescale: 1_000))))
    assertEnqueued(session.enqueue(RecordingPacket(mediaKind: .audio,
      presentationTime: resumed, duration: CMTime(value: 500, timescale: 1_000))))
    try session.drain()
    let summary = try session.finish()
    XCTAssertEqual(summary.finalState, .finalized)
    XCTAssertEqual(summary.packetCount, 8)
    XCTAssertEqual(writer.segments.last?.packets.first?.presentationTime,
      CMTime(value: 1_500, timescale: 1_000))
  }

  func testDiskFailureAndWriterFailureAreSticky() throws {
    let writer = MemorySegmentWriter()
    let config = LongRunRecordingConfiguration(minimumFreeBytes: 100,
      outputDirectory: URL(fileURLWithPath: "/tmp/ultrastudio-recording-test"))
    let session = try LongRunRecordingSession(configuration: config,
      diskSpace: FixedDiskSpace(99), writer: writer)
    XCTAssertThrowsError(try session.start())
    XCTAssertEqual(session.currentState, .idle, "Start failure must leave no active recording")

    let accepted = FixedDiskSpace(Int64.max)
    let second = try LongRunRecordingSession(configuration: config, diskSpace: accepted, writer: writer)
    try second.start()
    writer.failAppend = true
    assertEnqueued(second.enqueue(RecordingPacket(mediaKind: .video, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30))))
    XCTAssertThrowsError(try second.processNext())
    XCTAssertEqual(second.currentState, .failed)
    guard case .failure(.failed) = second.enqueue(RecordingPacket(mediaKind: .video,
      presentationTime: CMTime(value: 1, timescale: 30),
      duration: CMTime(value: 1, timescale: 30))) else {
      return XCTFail("Writer failure must reject later packets")
    }
  }

  func testAtomicWriterLeavesOnlyFinalizedFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultrastudio-recording-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = AtomicRecordingSegmentWriter(directory: directory, sessionID: "stress")
    try writer.beginSegment(index: 0, startTime: .zero)
    let packet = RecordingPacket(mediaKind: .video, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), payload: Data([1, 2, 3]))
    var normalizer = RecordingTimestampNormalizer()
    let normalized = try XCTUnwrap(normalizer.normalize(packet).successValue)
    try writer.append(normalized)
    let info = try writer.finalizeSegment(endTime: normalized.endTime)
    XCTAssertEqual(info.url?.pathExtension, "media")
    XCTAssertTrue(FileManager.default.fileExists(atPath: info.url!.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording-stress-segment-000000.part").path))
  }

  static let allTests = [
    ("large packet monotonicity", testNormalizerRemainsMonotonicAcrossLargePacketCount),
    ("A/V drift bound", testDriftBoundFailsWithoutDroppingTheOffendingPacket),
    ("queue overflow rejection", testQueueRejectsOverflowInsteadOfDropping),
    ("rollover and pause/resume", testSessionRollsOverAndPauseResumeKeepsTimelineContinuous),
    ("sticky failure", testDiskFailureAndWriterFailureAreSticky),
    ("atomic finalization", testAtomicWriterLeavesOnlyFinalizedFiles),
  ]
}

private extension Result where Failure: Error {
  var successValue: Success? {
    guard case let .success(value) = self else { return nil }
    return value
  }
}

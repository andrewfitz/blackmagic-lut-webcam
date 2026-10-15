import CoreMedia
import XCTest

@objcMembers final class ProgramTimestampMapperChecks: XCTestCase {
  private func time(_ value: Int64, _ timescale: Int32 = 60_000, epoch: Int64 = 0) -> CMTime {
    CMTime(value: value, timescale: timescale, flags: .valid, epoch: epoch)
  }

  private func frame(_ source: String, _ pts: Int64, duration: Int64 = 1,
                     timescale: Int32 = 60_000, epoch: Int64 = 0) -> ProgramSourceFrame<String> {
    ProgramSourceFrame(sourceID: source, sourceTime: time(pts, timescale, epoch: epoch),
      duration: time(duration, timescale))
  }

  private func mapped(_ result: Result<ProgramMappedFrame<String>, ProgramTimestampMappingError>,
                     file: StaticString = #filePath, line: UInt = #line) -> ProgramMappedFrame<String>? {
    guard case let .success(value) = result else {
      XCTFail("Expected mapped frame", file: file, line: line)
      return nil
    }
    return value
  }

  private func failure(_ result: Result<ProgramMappedFrame<String>, ProgramTimestampMappingError>,
                       equals expected: ProgramTimestampMappingError,
                       file: StaticString = #filePath, line: UInt = #line) {
    guard case let .failure(error) = result else {
      return XCTFail("Expected mapping failure", file: file, line: line)
    }
    XCTAssertEqual(error, expected, file: file, line: line)
  }

  func testFirstFrameAndSourceTimelineRemainMonotonic() {
    var mapper = ProgramTimestampMapper<String>(programTimescale: 60_000, selectedSource: "A")
    let first = mapped(mapper.map(frame("A", 10)))!
    let second = mapped(mapper.map(frame("A", 11)))!
    XCTAssertEqual(first.programTime, time(0))
    XCTAssertEqual(second.programTime, time(1))
    XCTAssertEqual(mapper.lastProgramTime, time(1))
  }

  func testCutResetsSourceOriginAtNextProgramBoundary() {
    var mapper = ProgramTimestampMapper<String>(selectedSource: "A")
    _ = mapped(mapper.map(frame("A", 500)))
    let prior = mapped(mapper.map(frame("A", 501)))!
    mapper.cut(to: "B")
    let cut = mapped(mapper.map(frame("B", 0)))!
    XCTAssertEqual(cut.programTime, CMTimeAdd(prior.programTime, prior.programDuration))
    XCTAssertGreaterThan(CMTimeCompare(cut.programTime, prior.programTime), 0)
  }

  func testRejectsForeignEpochTimebaseBackwardsAndInvalidDuration() {
    var mapper = ProgramTimestampMapper<String>(selectedSource: "A")
    failure(mapper.map(frame("A", 0, epoch: 1)), equals: .sourceEpochUnsupported(1))
    failure(mapper.map(frame("A", 0, duration: 0)), equals: .invalidSourceDuration)
    XCTAssertNotNil(mapped(mapper.map(frame("A", 0))))
    failure(mapper.map(frame("A", 0)), equals: .sourceTimestampRegressed)
    failure(mapper.map(frame("A", 2, timescale: 30_000)),
      equals: .sourceTimebaseChanged(expected: 60_000, actual: 30_000))
  }

  func testCutAppliesAtTargetBoundaryAndRequestsStaleFlush() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A valid target should queue")
    }
    if case .skipped(.staleQueuedFrame) = scheduler.ingest(frame("A", 0)) {} else {
      XCTFail("Queued old-source frames must be flushed")
    }
    guard case let .cutApplied(mapped, flushStaleFrames) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("Target frame should apply the pending cut")
    }
    XCTAssertTrue(flushStaleFrames)
    XCTAssertEqual(mapped.sourceID, "B")
    XCTAssertFalse(scheduler.hasPendingCut)
  }

  func testRapidCutsCoalesceToLatestTarget() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A valid target should queue")
    }
    guard case .coalesced(previous: "B", replacement: "C") = scheduler.requestCut(to: "C") else {
      return XCTFail("Rapid cuts should replace the pending target")
    }
    if case .skipped(.nonSelectedSource) = scheduler.ingest(frame("B", 0)) {} else {
      XCTFail("An intermediate rapid-cut target must not be emitted")
    }
    guard case let .cutApplied(mapped, _) = scheduler.ingest(frame("C", 0)) else {
      return XCTFail("Latest rapid-cut target should be selected")
    }
    XCTAssertEqual(mapped.sourceID, "C")
  }

  func testMissingSourcesAreRejectedAndPendingTargetIsDropped() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setSource("B", available: false)
    guard case .rejectedMissingSource = scheduler.requestCut(to: "B") else {
      return XCTFail("Unavailable target should be rejected")
    }
    guard case .skipped(.missingSource) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("Frames from an unavailable source should be skipped")
    }
    guard case let .accepted(mapped) = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("The selected source should continue")
    }
    XCTAssertEqual(mapped.programTime, time(0))
    XCTAssertFalse(scheduler.hasPendingCut)
  }

  static let allTests = [
    ("first frame and monotonic source timeline", testFirstFrameAndSourceTimelineRemainMonotonic),
    ("cut resets source origin", testCutResetsSourceOriginAtNextProgramBoundary),
    ("invalid source timing", testRejectsForeignEpochTimebaseBackwardsAndInvalidDuration),
    ("cut flushes stale frames", testCutAppliesAtTargetBoundaryAndRequestsStaleFlush),
    ("rapid cuts coalesce", testRapidCutsCoalesceToLatestTarget),
    ("missing sources", testMissingSourcesAreRejectedAndPendingTargetIsDropped),
  ]
}

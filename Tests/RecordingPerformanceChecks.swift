import CoreMedia
import XCTest

@objcMembers final class RecordingPerformanceChecks: XCTestCase {
  private let fastDuration = CMTime(value: 1_001, timescale: 60_000)

  func testPackedV210BudgetCoversOneAndTwoFeedsAt5994() throws {
    let one = try XCTUnwrap(RecordingPerformanceBudget(storage: .packedV210,
      width: 3_840, height: 2_160, frameDuration: fastDuration,
      feedCount: 1, queueFramesPerFeed: 12))
    XCTAssertEqual(one.bytesPerFrame, 22_118_400)
    XCTAssertEqual(one.aggregateBytesPerSecond, 1_325_778_222)
    XCTAssertEqual(one.retainedQueueBytes, 265_420_800)

    let two = try XCTUnwrap(RecordingPerformanceBudget(storage: .packedV210,
      width: 3_840, height: 2_160, frameDuration: fastDuration,
      feedCount: 2, queueFramesPerFeed: 12))
    XCTAssertTrue(two.isTwoFeed)
    XCTAssertEqual(two.aggregateBytesPerSecond, 2_651_556_444)
    XCTAssertEqual(two.retainedQueueBytes, 530_841_600)
  }

  func testPlanarTenBitAndNV12BudgetsUseActiveMediaBytes() throws {
    let planar = try XCTUnwrap(RecordingPerformanceBudget(storage: .biPlanar42210,
      width: 3_840, height: 2_160, frameDuration: fastDuration,
      feedCount: 2, queueFramesPerFeed: 12))
    XCTAssertEqual(planar.bytesPerFrame, 33_177_600)
    XCTAssertEqual(planar.aggregateBytesPerSecond, 3_977_334_666)

    let nv12 = try XCTUnwrap(RecordingPerformanceBudget(storage: .nv12,
      width: 1_920, height: 1_080, frameDuration: fastDuration,
      feedCount: 2, queueFramesPerFeed: 24))
    XCTAssertEqual(nv12.bytesPerFrame, 3_110_400)
    XCTAssertEqual(nv12.aggregateBytesPerSecond, 372_875_125)
    XCTAssertEqual(nv12.retainedQueueBytes, 149_299_200)
  }

  func testBudgetRejectsInvalidGeometryAndClock() {
    XCTAssertNil(RecordingPerformanceBudget(storage: .nv12, width: 1_921, height: 1_080,
      frameDuration: fastDuration))
    XCTAssertNil(RecordingPerformanceBudget(storage: .packedV210, width: 3_840, height: 2_160,
      frameDuration: .invalid))
    XCTAssertNil(RecordingPerformanceBudget(storage: .packedV210, width: 3_840, height: 2_160,
      frameDuration: fastDuration, feedCount: 0))
  }

  func testNoDropTelemetrySeparatesDropReasons() {
    let clean = RecordingDropSummary()
    XCTAssertTrue(clean.isLossless)
    let overloaded = RecordingDropSummary(queueFull: 1, writerNotReady: 2)
    XCTAssertEqual(overloaded.total, 3)
    XCTAssertFalse(overloaded.isLossless)
  }

  static let allTests = [
    ("v210 one and two feed budget", testPackedV210BudgetCoversOneAndTwoFeedsAt5994),
    ("planar and NV12 budget", testPlanarTenBitAndNV12BudgetsUseActiveMediaBytes),
    ("invalid performance budget", testBudgetRejectsInvalidGeometryAndClock),
    ("drop telemetry summary", testNoDropTelemetrySeparatesDropReasons),
  ]
}

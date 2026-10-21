import XCTest
@testable import MonitorToolsCore

final class MonitorAdaptivePolicyTests: XCTestCase {
  func testRepeatedPressureDegradesDespiteInterleavedSuccessAndRecoversAfterFiveSeconds() {
    var policy = MonitorAdaptivePolicy(requestedScopeHz: 30)
    XCTAssertEqual(policy.quality.pictureHeightLimit, 1080)
    policy.observe(now: 0, pressured: true)
    policy.observe(now: 0.2, pressured: false)
    policy.observe(now: 0.5, pressured: true)
    XCTAssertEqual(policy.observe(now: 0.7, pressured: false).tier, .nominal)
    let reduced = policy.observe(now: 1.1, pressured: true)
    XCTAssertEqual(reduced.tier, .reduced)
    XCTAssertEqual(reduced.pictureHeightLimit, 720)
    XCTAssertEqual(reduced.scopeSamplingStride, 4)
    XCTAssertEqual(reduced.scopeRefreshHz, 12)
    XCTAssertEqual(policy.observe(now: 5, pressured: false).tier, .reduced)
    policy.observe(now: 5.5, pressured: true)
    XCTAssertEqual(policy.observe(now: 10.49, pressured: false).tier, .reduced)
    XCTAssertEqual(policy.observe(now: 10.5, pressured: false).tier, .nominal)
    XCTAssertEqual(policy.quality.scopeRefreshHz, 30)
    XCTAssertEqual(MonitorEffectiveQuality(tier: .reduced, requestedScopeHz: 10).scopeRefreshHz, 10)
    XCTAssertEqual(MonitorEffectiveQuality(tier: .reduced, requestedScopeHz: 15).scopeRefreshHz, 12)
  }
  func testIsolatedPressureAndInvalidClockDoNotChangeQuality() {
    var policy = MonitorAdaptivePolicy(requestedScopeHz: 15)
    for time in [0.0, 2, 4] { policy.observe(now: time, pressured: true) }
    XCTAssertEqual(policy.quality.tier, .nominal)
    policy.observe(now: .nan, pressured: true)
    policy.observe(now: 1, pressured: true)
    XCTAssertEqual(policy.quality.tier, .nominal)
    policy.configure(requestedScopeHz: 10)
    XCTAssertEqual(policy.quality.scopeRefreshHz, 10)
    policy.configure(requestedScopeHz: Int.max)
    XCTAssertEqual(policy.quality.scopeRefreshHz, 15)
  }
  func testUniqueResultsRatesAgesAndSharedBudgetRemainDistinct() {
    var counters = MonitorDiagnosticsAccumulator()
    let target = MonitorTargetID("a")
    func stamp(_ sequence: UInt64, _ time: Double, _ generation: UInt64 = 1) -> MonitorFrameStamp {
      MonitorFrameStamp(target: target, generation: generation, sequence: sequence, sourcePTS: 10, hostTime: time, configurationRevision: 0)
    }
    for _ in 0..<4 { counters.recordOffer(now: 0) }
    counters.recordAdmission(now: 0)
    counters.recordAdmission(now: 0.5)
    counters.recordSkip(); counters.recordSkip(); counters.recordRejectedResult()
    counters.recordPicture(stamp(1, 0.1), now: 0.1)
    counters.recordPicture(stamp(1, 0.1), now: 0.2) // same shared result on another surface
    counters.recordPicture(stamp(2, 0.5), now: 0.5)
    counters.recordPicture(stamp(1, 0.1), now: 0.6) // old completion
    counters.recordScope(stamp(1, 0.1), now: 0.1)
    let ledger = MonitorAdmissionLedger(maximumBytes: 100, cleanReserveBytes: 0)
    let lease = ledger.tryAcquire(target: target, generation: 1, kind: .presentation, bytes: 20)
    ledger.retire(target: target, generation: 1)
    let value = counters.snapshot(now: 1, budget: ledger.snapshot, quality: MonitorEffectiveQuality(tier: .reduced), requestedScopeHz: 15, requestedPictureHz: 30, staleAfter: 0.5)
    XCTAssertEqual(value.offeredFrames, 4)
    XCTAssertEqual(value.admittedFrames, 2)
    XCTAssertEqual(value.skippedFrames, 2)
    XCTAssertEqual(value.rejectedResults, 1)
    XCTAssertEqual(value.offeredFPS, 4)
    XCTAssertEqual(value.admittedFPS, 2)
    XCTAssertEqual(value.pictureFPS, 2)
    XCTAssertEqual(value.scopeFPS, 1)
    XCTAssertEqual(value.pictureAge, 0.5)
    XCTAssertEqual(value.scopeAge ?? 0, 0.9, accuracy: 0.0001)
    XCTAssertTrue(value.scopeStale)
    XCTAssertEqual(value.softDeadlineStatus, .exceeded)
    XCTAssertEqual(value.retainedBytes, 20)
    XCTAssertEqual(value.retiredBytes, 20)
    XCTAssertEqual(value.requestedPictureHz, 30)
    XCTAssertEqual(value.requestedScopeHz, 15)
    XCTAssertEqual(value.effectiveQuality.scopeRefreshHz, 12)
    XCTAssertEqual(ledger.snapshot.reservations, 1) // a deadline does not release GPU resources
    let idle = counters.snapshot(now: 2, budget: ledger.snapshot, quality: MonitorEffectiveQuality(), requestedScopeHz: 15)
    XCTAssertEqual(idle.pictureFPS, 0)
    XCTAssertEqual(idle.scopeFPS, 0)
    lease?.release()
  }
  func testMissingResultsAndNewGenerationWithRepeatedPTS() {
    var counters = MonitorDiagnosticsAccumulator()
    let ledger = MonitorAdmissionLedger()
    let empty = counters.snapshot(now: 0, budget: ledger.snapshot, quality: MonitorEffectiveQuality(), requestedScopeHz: 15)
    XCTAssertNil(empty.pictureAge)
    XCTAssertTrue(empty.scopeStale)
    XCTAssertEqual(empty.softDeadlineStatus, .unavailable)
    let target = MonitorTargetID("a")
    for generation in 1...2 {
      let stamp = MonitorFrameStamp(target: target, generation: UInt64(generation), sequence: 1, sourcePTS: 0, hostTime: 0, configurationRevision: 0)
      counters.recordPicture(stamp, now: 0)
    }
    let value = counters.snapshot(now: 1, budget: ledger.snapshot, quality: MonitorEffectiveQuality(), requestedScopeHz: 15)
    XCTAssertEqual(value.pictureFPS, 2)
  }
}

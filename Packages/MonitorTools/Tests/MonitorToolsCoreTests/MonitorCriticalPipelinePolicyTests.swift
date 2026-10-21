import XCTest
@testable import MonitorToolsCore

final class MonitorCriticalPipelinePolicyTests: XCTestCase {
  func testExactDeadlineIsHealthyAndAnyBreachImmediatelyPauses() {
    var policy = MonitorCriticalPipelinePolicy()
    XCTAssertEqual(policy.observe(now: 0, queueAge: 0.125, processingTime: 0.125, frameInterval: 0.25), .nominal)
    XCTAssertEqual(policy.observe(now: 0.25, queueAge: 0.25.nextUp, processingTime: 0, frameInterval: 0.25), .paused)
  }
  func testFreshHealthyWindowsRecoverInTwoPhases() {
    var policy = MonitorCriticalPipelinePolicy()
    policy.observe(now: 0, queueAge: 0.3, processingTime: 0, frameInterval: 0.25)
    for index in 1...4 {
      XCTAssertEqual(policy.observe(now: Double(index) * 0.25, queueAge: 0, processingTime: 0.1, frameInterval: 0.25), .paused)
    }
    XCTAssertEqual(policy.observe(now: 1.25, queueAge: 0, processingTime: 0.1, frameInterval: 0.25), .recovering)
    for index in 6..<25 {
      XCTAssertEqual(policy.observe(now: Double(index) * 0.25, queueAge: 0, processingTime: 0.1, frameInterval: 0.25), .recovering)
    }
    XCTAssertEqual(policy.observe(now: 6.25, queueAge: 0, processingTime: 0.1, frameInterval: 0.25), .nominal)
  }
  func testSilenceAndSparseSamplesCannotRecoverAndTwoIntervalJitterIsAllowed() {
    var policy = MonitorCriticalPipelinePolicy()
    policy.observe(now: 0, queueAge: 1, processingTime: 0, frameInterval: 0.25)
    XCTAssertEqual(policy.phase, .paused)
    for time in [10.0, 20, 30] {
      XCTAssertEqual(policy.observe(now: time, queueAge: 0, processingTime: 0, frameInterval: 0.25), .paused)
    }
    XCTAssertEqual(policy.observe(now: 30.5, queueAge: 0, processingTime: 0, frameInterval: 0.25), .paused)
    XCTAssertEqual(policy.observe(now: 31, queueAge: 0, processingTime: 0, frameInterval: 0.25), .recovering)
    XCTAssertEqual(policy.observe(now: 40, queueAge: 0, processingTime: 0, frameInterval: 0.25), .recovering)
    for index in 1..<10 {
      XCTAssertEqual(policy.observe(now: 40 + Double(index) * 0.5, queueAge: 0, processingTime: 0, frameInterval: 0.25), .recovering)
    }
    XCTAssertEqual(policy.observe(now: 45, queueAge: 0, processingTime: 0, frameInterval: 0.25), .nominal)
  }
  func testAnyNewBreachResetsPausedAndRecoveringHealth() {
    var policy = MonitorCriticalPipelinePolicy()
    policy.observe(now: 0, queueAge: 1, processingTime: 0, frameInterval: 0.25)
    for index in 1...5 { policy.observe(now: Double(index) * 0.25, queueAge: 0, processingTime: 0, frameInterval: 0.25) }
    XCTAssertEqual(policy.phase, .recovering)
    XCTAssertEqual(policy.observe(now: 1.5, queueAge: 0, processingTime: 0.26, frameInterval: 0.25), .paused)
    for index in 7...10 {
      XCTAssertEqual(policy.observe(now: Double(index) * 0.25, queueAge: 0, processingTime: 0, frameInterval: 0.25), .paused)
    }
    XCTAssertEqual(policy.observe(now: 2.75, queueAge: 0, processingTime: 0, frameInterval: 0.25), .recovering)
  }
  func testInvalidAndBackwardSamplesCannotAdvanceRecoveryAndStopRequiresReset() {
    var policy = MonitorCriticalPipelinePolicy()
    policy.observe(now: 0, queueAge: 1, processingTime: 0, frameInterval: 0.25)
    policy.observe(now: 0.25, queueAge: 0, processingTime: 0, frameInterval: 0.25)
    for sample in [
      (Double.nan, 0.0, 0.0, 0.25), (Double.infinity, 0, 0, 0.25),
      (-1, 0, 0, 0.25), (0.1, 0, 0, 0.25), (0.25, 0, 0, 0.25),
      (0.5, -1, 0, 0.25), (0.5, 0, Double.nan, 0.25), (0.5, 0, 0, 0)
    ] {
      XCTAssertEqual(policy.observe(now: sample.0, queueAge: sample.1, processingTime: sample.2, frameInterval: sample.3), .paused)
    }
    policy.stop()
    for index in 1...40 { XCTAssertEqual(policy.observe(now: Double(index), queueAge: 0, processingTime: 0, frameInterval: 1), .paused) }
    policy.reset()
    XCTAssertEqual(policy.phase, .nominal)
    XCTAssertEqual(policy.observe(now: 0, queueAge: 0, processingTime: 0, frameInterval: 1), .nominal)
  }
}

import XCTest

@objcMembers final class AutomaticFeedChecks: XCTestCase {
  func testNoCaptureWithoutDemandEvenWithReadyPreview() {
    var policy = AutomaticFeedPolicy()
    XCTAssertNil(policy.action(ready: true, running: false))
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
  }

  func testWaitsForLUTAndStartsOncePerSession() {
    var policy = AutomaticFeedPolicy()
    policy.demand(true)
    XCTAssertNil(policy.action(ready: false, running: false))
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(true)
    XCTAssertNil(policy.action(ready: true, running: true))
    XCTAssertNil(policy.action(ready: true, running: false), "Failed start must not spin on repeated notifications")
    policy.retry()
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }

  func testStopWhileLoadingAndNewSessionRecovery() {
    var policy = AutomaticFeedPolicy()
    policy.demand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: false), "Closed request cannot start after LUT finishes")
    policy.demand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(false)
    XCTAssertEqual(policy.action(ready: false, running: true), .stop)
    policy.demand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }
}

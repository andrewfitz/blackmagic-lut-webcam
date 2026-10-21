import XCTest

@objcMembers final class AutomaticFeedChecks: XCTestCase {
  func testNoCaptureWithoutCameraOrVisiblePreviewDemand() {
    var policy = AutomaticFeedPolicy()
    XCTAssertNil(policy.action(ready: true, running: false))
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
  }

  func testVisiblePreviewStartsWithoutACameraAppAndHidingStops() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertFalse(policy.requested, "Local preview must not pretend a camera client is connected")
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.previewDemand(false)
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
  }

  func testPreviewAndCameraDemandKeepEachOtherAlive() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.demand(true)
    policy.previewDemand(false)
    XCTAssertNil(policy.action(ready: true, running: true), "Hiding preview must preserve camera output")
    policy.previewDemand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: true), "Closing a camera app must preserve visible preview")
    policy.previewDemand(false)
    XCTAssertEqual(policy.action(ready: true, running: true), .stop)
  }

  func testFailedPreviewStartDoesNotRetryUntilNewDemandSession() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    XCTAssertNil(policy.action(ready: false, running: false))
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
    policy.previewDemand(true)
    policy.demand(true)
    policy.demand(false)
    XCTAssertNil(policy.action(ready: true, running: false))
    policy.previewDemand(false)
    policy.previewDemand(true)
    XCTAssertEqual(policy.action(ready: true, running: false), .start)
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

import Foundation
import XCTest

final class DeckLinkChecks: XCTestCase {
  func testNativeSDKCallbacksAndLifecycle() {
    var error: NSError?
    XCTAssertTrue(UDLRunSyntheticChecks(&error), error?.localizedDescription ?? "Native SDK checks failed")
  }

  func testStopBeforeStartIsIdempotent() {
    let backend = UDLBackend()
    backend.stop()
    backend.stop()
  }

  func testMissingDeviceFailsCleanlyAndCanStop() {
    let backend = UDLBackend()
    XCTAssertThrowsError(try backend.start(deviceID: "synthetic:missing-device", inputFast: true,
      frameHandler: { _, _, _ in XCTFail("Missing device delivered a frame") },
      eventHandler: { _ in XCTFail("Missing device unexpectedly started its callback") }))
    backend.stop()
  }

  static let allTests = [
    ("native SDK callbacks, frame ownership, lifecycle and HDMI restore", testNativeSDKCallbacksAndLifecycle),
    ("native stop before start is idempotent", testStopBeforeStartIsIdempotent),
    ("native missing-device startup cleans up", testMissingDeviceFailsCleanlyAndCanStop),
  ]
}

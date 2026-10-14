import Foundation
import XCTest

final class DeckLinkChecks: XCTestCase {
  func testAutomaticInputDetectionAndTransitions() {
    var error: NSError?
    XCTAssertTrue(UDLRunAutoSyntheticChecks(&error), error?.localizedDescription ?? "Native auto detection failed")
  }
  func testNativeSDKCallbacksAndLifecycle() {
    var error: NSError?
    XCTAssertTrue(UDLRunSyntheticChecks(&error), error?.localizedDescription ?? "Native SDK checks failed")
  }

  func testStopBeforeStartIsIdempotent() {
    let backend = UDLBackend()
    backend.stop()
    backend.stop()
  }

  func testMissingAutoDeviceFailsCleanly() {
    let backend = UDLBackend()
    XCTAssertThrowsError(try backend.startAuto(deviceID: "synthetic:missing-device",
      frameHandler: { _, _, _, _ in XCTFail("Missing auto device delivered a frame") },
      eventHandler: { _ in XCTFail("Missing auto device started a callback") }))
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
    ("automatic HDMI detection and live transitions", testAutomaticInputDetectionAndTransitions),
    ("missing automatic device fails cleanly", testMissingAutoDeviceFailsCleanly),
    ("native SDK callbacks, frame ownership, lifecycle and HDMI restore", testNativeSDKCallbacksAndLifecycle),
    ("native stop before start is idempotent", testStopBeforeStartIsIdempotent),
    ("native missing-device startup cleans up", testMissingDeviceFailsCleanlyAndCanStop),
  ]
}

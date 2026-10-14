import XCTest

@objcMembers final class CameraAuthorizationChecks: XCTestCase {
  func testKnownProducerKeepsExistingAuthorization() {
    XCTAssertTrue(CameraProducerAuthorization.allows(signingID: "org.ultrastudiolut.app", pid: 123) { _ in
      XCTFail("CMIO supplied the expected signing identifier; no local fallback is needed")
      return false
    })
  }

  func testMissingIdentifiersRequireLocalCompilationAndVerifiedProcess() {
    for identifier: String? in [nil, "unknown"] {
      var checkedPID: pid_t?
      let allowed = CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { pid in
        checkedPID = pid
        return true
      }
#if UDL_LOCAL_DEVELOPMENT
      XCTAssertTrue(allowed)
      XCTAssertEqual(checkedPID, 123)
#else
      XCTAssertFalse(allowed)
      XCTAssertNil(checkedPID, "Production never consults a local-process override")
#endif
    }
  }

  func testMissingIdentifiersRejectUnverifiedProcess() {
    for identifier: String? in [nil, "unknown"] {
      XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { _ in false })
    }
  }

  func testOtherIdentifiersAndInvalidPIDsNeverUseFallback() {
    for identifier: String? in ["", "org.other.app", "UNKNOWN"] {
      XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { _ in
        XCTFail("An explicit mismatching identifier must never use the fallback")
        return true
      })
    }
    for identifier: String? in [nil, "unknown"] {
      for pid: pid_t in [0, -1] {
        XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: pid) { _ in
          XCTFail("An invalid PID must never be verified")
          return true
        })
      }
    }
  }

}

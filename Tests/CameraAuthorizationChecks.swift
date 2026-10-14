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

#if UDL_LOCAL_DEVELOPMENT
  func testStaticVerificationRequiresStableExecutableAndValidSignature() {
    var lookupCount = 0
    var signatureCount = 0
    let status = CameraProducerAuthorization.verifyStaticProcess(pid: 123, pathForPID: { pid in
      XCTAssertEqual(pid, 123)
      lookupCount += 1
      return "/Applications/UltraStudio LUT.app/Contents/MacOS/UltraStudio LUT"
    }, validate: { path in
      XCTAssertTrue(path.hasPrefix("/Applications/"))
      signatureCount += 1
      return 0
    })
    XCTAssertEqual(status, 0)
    XCTAssertEqual(lookupCount, 2, "Recheck the process path after validating signed bytes")
    XCTAssertEqual(signatureCount, 1)
  }

  func testStaticVerificationRejectsUnavailableChangedOrInvalidCode() {
    for path: String? in [nil, "", "relative-executable"] {
      XCTAssertNotEqual(CameraProducerAuthorization.verifyStaticProcess(pid: 123,
        pathForPID: { _ in path }, validate: { _ in
          XCTFail("Never validate a missing or relative executable path")
          return 0
        }), 0)
    }
    XCTAssertNotEqual(CameraProducerAuthorization.verifyStaticProcess(pid: 0,
      pathForPID: { _ in XCTFail("Invalid PID"); return "/test" }, validate: { _ in 0 }), 0)
    XCTAssertEqual(CameraProducerAuthorization.verifyStaticProcess(pid: 123,
      pathForPID: { _ in "/test" }, validate: { _ in -67050 }), -67050)
    var lookups = 0
    XCTAssertNotEqual(CameraProducerAuthorization.verifyStaticProcess(pid: 123, pathForPID: { _ in
      lookups += 1
      return lookups == 1 ? "/original" : "/replacement"
    }, validate: { _ in 0 }), 0)
    lookups = 0
    XCTAssertNotEqual(CameraProducerAuthorization.verifyStaticProcess(pid: 123, pathForPID: { _ in
      lookups += 1
      return lookups == 1 ? "/original" : nil
    }, validate: { _ in 0 }), 0)
  }
#endif
}

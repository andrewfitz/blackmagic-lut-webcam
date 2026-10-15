import AVFoundation
import CoreVideo
import XCTest

private struct FakeHEVCEncoderCatalog: HEVCEncoderCatalog {
  let values: [HEVCEncoderCandidate]

  func candidates(width: Int, height: Int, profile: HEVCRecordingProfile) throws -> [HEVCEncoderCandidate] {
    values
  }
}

@objcMembers final class HEVCRecordingChecks: XCTestCase {
  private let profile = HEVCRecordingProfile.main10_422

  func testHardwarePreferredSelectsExactHardwareProfile() throws {
    let catalog = FakeHEVCEncoderCatalog(values: [
      HEVCEncoderCandidate(encoderID: "software", isHardwareAccelerated: false, supportsMain10_422: true),
      HEVCEncoderCandidate(encoderID: "hardware", isHardwareAccelerated: true, supportsMain10_422: true),
    ])
    let config = HEVCRecordingConfiguration(width: 3840, height: 2160, frameRate: 59.94,
      encoderPreference: .hardwarePreferred)
    let result = try HEVCRecordingCapabilityProbe(catalog: catalog).selectEncoder(for: config)
    XCTAssertEqual(result.encoderID, "hardware")
    XCTAssertTrue(result.isHardwareAccelerated)
    XCTAssertNil(result.fallbackReason)
  }

  func testHardwarePreferredFallsBackOnlyToExactSoftwareProfile() throws {
    let catalog = FakeHEVCEncoderCatalog(values: [
      HEVCEncoderCandidate(encoderID: "main10-420", isHardwareAccelerated: true, supportsMain10_422: false),
      HEVCEncoderCandidate(encoderID: "software-422", isHardwareAccelerated: false, supportsMain10_422: true),
    ])
    let config = HEVCRecordingConfiguration(width: 1920, height: 1080, frameRate: 29.97)
    let result = try HEVCRecordingCapabilityProbe(catalog: catalog).selectEncoder(for: config)
    XCTAssertEqual(result.encoderID, "software-422")
    XCTAssertFalse(result.isHardwareAccelerated)
    XCTAssertNotNil(result.fallbackReason)
  }

  func testHardwareRequiredRejectsSoftwareFallback() {
    let catalog = FakeHEVCEncoderCatalog(values: [
      HEVCEncoderCandidate(encoderID: "software-422", isHardwareAccelerated: false, supportsMain10_422: true),
    ])
    let config = HEVCRecordingConfiguration(width: 1920, height: 1080, frameRate: 29.97,
      encoderPreference: .hardwareRequired)
    XCTAssertThrowsError(try HEVCRecordingCapabilityProbe(catalog: catalog).selectEncoder(for: config)) { error in
      XCTAssertEqual(error as? HEVCRecordingError, .hardwareEncoderUnavailable(self.profile))
    }
  }

  func testUnsupportedProfileNeverDowngradesToMain10Or420() {
    let catalog = FakeHEVCEncoderCatalog(values: [
      HEVCEncoderCandidate(encoderID: "main10-420", isHardwareAccelerated: true, supportsMain10_422: false),
    ])
    let config = HEVCRecordingConfiguration(width: 1920, height: 1080, frameRate: 29.97)
    XCTAssertThrowsError(try HEVCRecordingCapabilityProbe(catalog: catalog).selectEncoder(for: config)) { error in
      XCTAssertEqual(error as? HEVCRecordingError, .unsupportedProfile(self.profile))
    }
  }

  func testWriterSettingsDeclareMain42210AndExactInputFormat() throws {
    let selection = HEVCEncoderSelection(encoderID: "hardware", isHardwareAccelerated: true,
      profile: profile, fallbackReason: nil)
    let config = HEVCRecordingConfiguration(width: 3840, height: 2160, frameRate: 59.94,
      averageBitRate: 120_000_000)
    let settings = HEVCAssetWriterContract.outputSettings(configuration: config, selection: selection)
    XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
    XCTAssertEqual(settings[AVVideoProfileLevelKey] as? String, profile.profileLevel)
    XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 3840)
    XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 2160)
    let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
    XCTAssertEqual(compression[kVTCompressionPropertyKey_ProfileLevel as String] as? String, profile.profileLevel)
    XCTAssertEqual(compression[kVTCompressionPropertyKey_AverageBitRate as String] as? Int, 120_000_000)
    let attributes = HEVCAssetWriterContract.pixelBufferAttributes(for: profile)
    XCTAssertEqual(attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType, profile.pixelFormat)
  }

  func testInvalidConfigurationIsRejectedBeforeProbe() {
    let config = HEVCRecordingConfiguration(width: 0, height: 1080, frameRate: 29.97)
    XCTAssertThrowsError(try HEVCRecordingCapabilityProbe(catalog: FakeHEVCEncoderCatalog(values: [])).selectEncoder(for: config)) { error in
      XCTAssertEqual(error as? HEVCRecordingError, .invalidDimensions)
    }
  }

  func testSystemProbeFindsHardwareMain422WhenAvailable() throws {
    let config = HEVCRecordingConfiguration(width: 1920, height: 1080, frameRate: 29.97)
    do {
      let result = try HEVCRecordingCapabilityProbe().selectEncoder(for: config)
      XCTAssertEqual(result.profile, .main10_422)
      XCTAssertFalse(result.encoderID.isEmpty)
    } catch HEVCRecordingError.noVideoEncoder {
      throw XCTSkip("Host does not expose a VideoToolbox HEVC encoder.")
    } catch HEVCRecordingError.unsupportedProfile {
      throw XCTSkip("Host HEVC encoders do not expose Main 10 4:2:2.")
    }
  }

  static let allTests = [
    ("hardware preferred selection", testHardwarePreferredSelectsExactHardwareProfile),
    ("exact software fallback", testHardwarePreferredFallsBackOnlyToExactSoftwareProfile),
    ("hardware required", testHardwareRequiredRejectsSoftwareFallback),
    ("no profile downgrade", testUnsupportedProfileNeverDowngradesToMain10Or420),
    ("writer settings", testWriterSettingsDeclareMain42210AndExactInputFormat),
    ("invalid configuration", testInvalidConfigurationIsRejectedBeforeProbe),
    ("system capability", testSystemProbeFindsHardwareMain422WhenAvailable),
  ]
}

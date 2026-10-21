import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

final class ProResRecordingConfigurationChecks: XCTestCase {
  private func source(frameDuration: CMTime = CMTime(value: 1001, timescale: 30_000)) throws
    -> ProRes422SourceFormat {
    try ProRes422SourceFormat(
      width: 1_920, height: 1_080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      frameDuration: frameDuration)
  }

  func testSettingsPreserveSourceGeometryAndTenBitFormat() throws {
    let configuration = try ProResRecordingConfiguration(
      source: source(), profile: .highQuality, encoderAvailability: .assumedAvailable)

    XCTAssertEqual(configuration.videoSettings[AVVideoCodecKey] as? AVVideoCodecType,
      .proRes422HQ)
    XCTAssertEqual(configuration.videoSettings[AVVideoWidthKey] as? Int, 1_920)
    XCTAssertEqual(configuration.videoSettings[AVVideoHeightKey] as? Int, 1_080)
    XCTAssertNil(configuration.videoSettings[AVVideoScalingModeKey])
    XCTAssertNil(configuration.videoSettings[AVVideoColorPropertiesKey])
    XCTAssertEqual(configuration.sourcePixelBufferAttributes[
      kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(configuration.sourcePixelBufferAttributes[
      kCVPixelBufferWidthKey as String] as? Int, 1_920)
    XCTAssertEqual(configuration.sourcePixelBufferAttributes[
      kCVPixelBufferHeightKey as String] as? Int, 1_080)
    XCTAssertEqual(configuration.makeVideoInput().mediaType, .video)
    XCTAssertEqual(configuration.makeTimecodeInput().mediaType, .timecode)
  }

  func testUnsupportedModeErrorsNameTheActualMode() {
    XCTAssertThrowsError(try ProRes422SourceFormat(
      width: 1_919, height: 1_080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10,
      frameDuration: CMTime(value: 1001, timescale: 30_000))) { error in
      XCTAssertEqual((error as? ProResRecordingError),
        .dimensionsMustBeEven(width: 1_919, height: 1_080))
      XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("1919") == true)
    }
    XCTAssertThrowsError(try ProRes422SourceFormat(
      width: 1_920, height: 1_080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      frameDuration: CMTime(value: 1001, timescale: 30_000))) { error in
      XCTAssertEqual((error as? ProResRecordingError),
        .unsupportedPixelFormat(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    }
    XCTAssertThrowsError(try ProRes422SourceFormat(
      width: 1_920, height: 1_080, pixelFormat: kCVPixelFormatType_422YpCbCr10,
      frameDuration: CMTime(value: 1, timescale: 29))) { error in
      XCTAssertEqual((error as? ProResRecordingError)?.errorDescription?.contains("frame rate"), true)
    }
  }

  func testVideoToolboxUnavailableIsActionable() throws {
    XCTAssertThrowsError(try ProResRecordingConfiguration(
      source: source(), encoderAvailability: .unavailable("test capability failure"))) { error in
      guard let error = error as? ProResRecordingError else {
        return XCTFail("Expected ProResRecordingError, got \(error)")
      }
      XCTAssertEqual(error.errorDescription,
        "VideoToolbox has no Apple ProRes 422 encoder for 1920 × 1080: test capability failure.")
    }
  }

  func testTimecodeTrackCarriesDropFrameMetadataAndBigEndianFrame() throws {
    let frameRate = try ProResFrameRate(frameDuration: CMTime(value: 1001, timescale: 30_000))
    let track = try ProResTimecodeTrack(frameRate: frameRate, sourceReferenceName: "camera")
    XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(track.formatDescription), 30)
    XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(track.formatDescription),
      UInt32(kCMTimeCodeFlag_DropFrame))
    let sample = try track.makeSample(frameNumber: 0x0102_0304, presentationTime: .zero)
    XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 4)
    var bytes = [UInt8](repeating: 0, count: 4)
    let status = bytes.withUnsafeMutableBytes { destination in
      guard let block = CMSampleBufferGetDataBuffer(sample) else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4,
        destination: destination.baseAddress!)
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04])
    XCTAssertEqual(track.makeInput().mediaType, .timecode)
  }

  func testSystemProbeFindsProResEncoderOnSupportedHost() throws {
    let info = try ProResRecordingConfiguration.inspectEncoder(
      profile: .standard, width: 1_920, height: 1_080)
    XCTAssertFalse(info.encoderID.isEmpty)
    XCTAssertTrue(info.supportedPropertyKeys.contains("ExpectedFrameRate"))
  }

  func testEncodeSubmissionAllowsOutputCallbackToAcquireWriterLock() throws {
    final class WriterReference: @unchecked Sendable {
      weak var writer: AVAssetSourceRecordingWriter?
    }
    let reference = WriterReference()
    let callbackRead = DispatchSemaphore(value: 0)
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("lock-check"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-lock-check.mov"),
      width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    let writer = try AVAssetSourceRecordingWriter(configuration: configuration, encodeFrame: { _, _, _, _ in
      DispatchQueue.global().async {
        _ = reference.writer?.telemetry
        callbackRead.signal()
      }
      // Models a remote encoder waiting for a callback on another thread.
      // The pre-fix lock inversion fails promptly instead of hanging XCTest.
      return callbackRead.wait(timeout: .now() + 1) == .success ? noErr : -1
    })
    reference.writer = writer
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let sample = try VideoContract.sample(try XCTUnwrap(image), at: .zero, duration: VideoContract.fastDuration)
    try writer.start()
    XCTAssertNoThrow(try writer.appendVideo(sample))
    XCTAssertNoThrow(try writer.finish())
  }

  func testSourceRecorderInfersExactHardwareProfiles() throws {
    let hevc = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("hevc"),
      outputURL: URL(fileURLWithPath: "/tmp/hevc.mov"), width: 3_840, height: 2_160,
      videoCodec: kCMVideoCodecType_HEVC)
    XCTAssertEqual(hevc.videoProfile, .hevcMain10_422)
    XCTAssertEqual(hevc.videoProfile.profileLevel,
      kVTProfileLevel_HEVC_Main42210_AutoLevel as String)
    XCTAssertEqual(hevc.videoProfile.sourcePixelFormat, kCVPixelFormatType_422YpCbCr10)
    let specification = hevc.videoProfile.encoderSpecification as NSDictionary
    XCTAssertEqual((specification.object(
      forKey: kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder) as? NSNumber)?.boolValue,
      true)

    let proRes = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("prores"),
      outputURL: URL(fileURLWithPath: "/tmp/prores.mov"), width: 3_840, height: 2_160,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    XCTAssertEqual(proRes.videoProfile, .proRes422(.highQuality))
    XCTAssertNil(proRes.videoProfile.profileLevel)
    XCTAssertEqual(proRes.videoProfile.codecType, kCMVideoCodecType_AppleProRes422HQ)
  }

  func testSourceRecorderRejectsProfileCodecMismatch() {
    XCTAssertThrowsError(try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("mismatch"),
      outputURL: URL(fileURLWithPath: "/tmp/mismatch.mov"), width: 16, height: 16,
      videoCodec: kCMVideoCodecType_HEVC,
      videoProfile: .proRes422(.standard))) { error in
      guard case let SourceRecordingError.invalidConfiguration(message) = error else {
        return XCTFail("Expected an invalid profile configuration, got \(error)")
      }
      XCTAssertTrue(message.contains("does not match"))
    }
  }

  static let allTests = [
    ("settings preserve geometry and ten-bit format", testSettingsPreserveSourceGeometryAndTenBitFormat),
    ("unsupported mode errors name actual mode", testUnsupportedModeErrorsNameTheActualMode),
    ("VideoToolbox unavailable is actionable", testVideoToolboxUnavailableIsActionable),
    ("timecode track carries metadata", testTimecodeTrackCarriesDropFrameMetadataAndBigEndianFrame),
    ("system probe finds ProRes encoder", testSystemProbeFindsProResEncoderOnSupportedHost),
    ("source recorder profile contract", testSourceRecorderInfersExactHardwareProfiles),
    ("source recorder profile mismatch", testSourceRecorderRejectsProfileCodecMismatch),
  ]
}

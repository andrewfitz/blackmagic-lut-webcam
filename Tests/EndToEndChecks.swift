import CoreMedia
import CoreVideo
import Foundation
import XCTest

// Exercise the real pixel processor, rational cadence selector, and sample
// construction together. These checks need neither capture hardware nor an
// installed/signed camera extension, and never store source imagery on disk.
@objcMembers final class EndToEndChecks: XCTestCase {
  private func source(luma: (Int) -> UInt16 = { _ in 283 }) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
      &buffer)
    XCTAssertEqual(status, kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane) / MemoryLayout<UInt16>.stride
      var row = [UInt16](repeating: 512 << 6, count: stride)
      if plane == 0 {
        for x in 0..<3840 { row[x] = luma(x) << 6 }
      }
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane))
      row.withUnsafeBytes { bytes in
        for y in 0..<2160 {
          memcpy(base.advanced(by: y * bytes.count), bytes.baseAddress!, bytes.count)
        }
      }
    }
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return image
  }

  private func luma(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
    if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
      return Int(row.assumingMemoryBound(to: UInt8.self)[x])
    }
    return Int(row.assumingMemoryBound(to: UInt16.self)[x] >> 6)
  }

  func testAllSwitchesAndBothRatesProduceUsableSamples() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(transform: { 1 - $0 })))
    let input = try source()
    // Every checkbox is independent, including rate reduction. Test both
    // source rates: reducing a 29.97 source must never halve it again.
    for inputFast in [false, true] {
      for bits in 0..<16 {
        try autoreleasepool {
          let config = PipelineConfiguration(applyLUT: bits & 1 != 0, downscale: bits & 2 != 0,
            convertTo420: bits & 4 != 0, reduceFrameRate: bits & 8 != 0, inputFast: inputFast)
          let output = try processor.process(input, configuration: config)
          XCTAssertEqual(CVPixelBufferGetWidth(output), bits & 2 != 0 ? 1920 : 3840)
          XCTAssertEqual(CVPixelBufferGetHeight(output), bits & 2 != 0 ? 1080 : 2160)
          XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), bits & 4 != 0 ?
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
          let expectedCode = config.convertTo420 ? (config.applyLUT ? 180 : 71) : (config.applyLUT ? 721 : 283)
          for point in [(0, 0), (config.width / 2, config.height / 2), (config.width - 1, config.height - 1)] {
            XCTAssertEqual(Double(try luma(output, x: point.0, y: point.1)), Double(expectedCode), accuracy: 1,
              "Constant neutral image must survive processing and scaling, flags=\(bits), inputFast=\(inputFast)")
          }
          if config.untouched { XCTAssertTrue(output === input) }

          let inputDuration = inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          let expectedDuration = CMTime(value: 1001, timescale: inputFast && bits & 8 == 0 ? 60_000 : 30_000)
          var gate = FrameRateGate()
          var delivered = [CMTime]()
          let hostOrigin = CMTime(value: 120, timescale: 1)
          for frame in 0..<6 {
            let sourcePTS = CMTimeMultiply(inputDuration, multiplier: Int32(frame))
            guard gate.shouldDeliver(sourcePTS, duration: config.duration) else { continue }
            let outputPTS = CMTimeAdd(hostOrigin, sourcePTS)
            let sample = try VideoContract.sample(output, at: outputPTS, duration: config.duration)
            XCTAssertTrue(CMSampleBufferDataIsReady(sample))
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === output)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), outputPTS)
            XCTAssertEqual(CMSampleBufferGetDuration(sample), expectedDuration)
            XCTAssertFalse(CMSampleBufferGetDecodeTimeStamp(sample).isValid)
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let size = CMVideoFormatDescriptionGetDimensions(description)
            XCTAssertEqual(size.width, Int32(config.width))
            XCTAssertEqual(size.height, Int32(config.height))
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), CVPixelBufferGetPixelFormatType(output))
            delivered.append(outputPTS)
          }
          XCTAssertEqual(delivered.count, inputFast && config.reduceFrameRate ? 3 : 6)
          for index in 1..<delivered.count {
            XCTAssertEqual(CMTimeSubtract(delivered[index], delivered[index - 1]), expectedDuration)
          }
        }
      }
    }
  }

  func testNoLUTFileNeededWithEveryOtherSwitchCombination() throws {
    let processor = try LUTProcessor()
    let input = try source()
    for bits in 0..<8 {
      try autoreleasepool {
        let config = PipelineConfiguration(applyLUT: false, downscale: bits & 1 != 0,
          convertTo420: bits & 2 != 0, reduceFrameRate: bits & 4 != 0, inputFast: true)
        let output = try processor.process(input, configuration: config)
        let sample = try VideoContract.sample(output, at: .zero, duration: config.duration)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(Double(try luma(output, x: config.width / 2, y: config.height / 2)),
          config.convertTo420 ? 71 : 283, accuracy: 1)
      }
    }
    XCTAssertThrowsError(try processor.process(input, configuration: PipelineConfiguration(
      applyLUT: true, downscale: false, convertTo420: false, reduceFrameRate: false, inputFast: true)),
      "An enabled, missing LUT must report an error instead of reading an uninitialized cube")
  }

  func testLUTConsumesTenBitPrecisionBeforeEightBitQuantization() throws {
    let processor = try LUTProcessor()
    // A domain expansion makes adjacent 10-bit log levels distinguishable in
    // final 8-bit output. Early 8-bit conversion would irreversibly collapse
    // most of these 80 levels, even though the final file format looks right.
    let cube = cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2",
      with: "LUT_3D_SIZE 2\nDOMAIN_MIN 0.35 0.35 0.35\nDOMAIN_MAX 0.55 0.55 0.55")
    try processor.load(CubeLUT(text: cube))
    let input = try source { UInt16(400 + $0 % 80) }
    let config = PipelineConfiguration(applyLUT: true, downscale: false,
      convertTo420: true, reduceFrameRate: false, inputFast: true)
    let output = try processor.process(input, configuration: config)
    var levels = Set<Int>()
    for x in 0..<80 {
      let actual = try luma(output, x: x, y: 1080)
      let logRGB = Double(400 + x - 64) / 876
      let expected = 16 + 219 * ((logRGB - 0.35) / 0.2)
      XCTAssertEqual(Double(actual), expected, accuracy: 1)
      levels.insert(actual)
    }
    XCTAssertEqual(levels.count, 80, "Every adjacent source level must reach the LUT before output quantization")
    let sample = try VideoContract.sample(output, at: VideoContract.fastDuration, duration: config.duration)
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMFormatDescriptionGetExtension(description,
      extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertEqual(CMFormatDescriptionGetExtension(description,
      extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
      kCVImageBufferTransferFunction_ITU_R_709_2 as String)
  }

  func testPoolBackpressureIsBoundedAndRecoversAfterConsumerReleases() throws {
    let processor = try LUTProcessor()
    let input = try source()
    let config = PipelineConfiguration(applyLUT: false, downscale: true,
      convertTo420: true, reduceFrameRate: false, inputFast: true)
    var retained = [CVPixelBuffer]()
    for frame in 0..<8 {
      let output = try processor.process(input, configuration: config)
      // Simulate consumer retention, as would happen with an occupied CMIO
      // queue. Distinct frames must not overwrite already published buffers.
      XCTAssertFalse(retained.contains { $0 === output })
      let sample = try VideoContract.sample(output,
        at: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)), duration: config.duration)
      XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === output)
      retained.append(output)
    }
    XCTAssertThrowsError(try processor.process(input, configuration: config),
      "A stalled consumer must not cause unbounded allocation")
    retained.removeAll()
    let recovered = try processor.process(input, configuration: config)
    XCTAssertEqual(Double(try luma(recovered, x: 960, y: 540)), 71, accuracy: 1)
  }

  func testCadenceSurvivesSourceLossInvalidTimesAndClockRestart() throws {
    var gate = FrameRateGate()
    let inputDuration = VideoContract.fastDuration
    let deliveredFrames = (0..<12).filter { frame in
      // Frame 2 would normally be delivered but is lost at capture. Frame 3
      // can be delivered next; the gate must avoid freezing after a gap.
      guard frame != 2 else { return false }
      return gate.shouldDeliver(CMTimeMultiply(inputDuration, multiplier: Int32(frame)),
        duration: VideoContract.slowDuration)
    }
    XCTAssertEqual(deliveredFrames, [0, 3, 5, 7, 9, 11])
    XCTAssertFalse(gate.shouldDeliver(.invalid, duration: VideoContract.slowDuration))
    XCTAssertFalse(gate.shouldDeliver(.indefinite, duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(.zero, duration: VideoContract.slowDuration),
      "A replacement source with a reset PTS must restart cadence immediately")
    XCTAssertFalse(gate.shouldDeliver(.zero, duration: VideoContract.slowDuration),
      "Duplicate timestamps must not be published twice")
    XCTAssertFalse(gate.shouldDeliver(inputDuration, duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(VideoContract.slowDuration, duration: VideoContract.slowDuration))
  }
}

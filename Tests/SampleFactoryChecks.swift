import CoreMedia
import CoreVideo
import Foundation
import XCTest

private final class FactoryReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var releases: Int { lock.withLock { count } }
  func released() { lock.withLock { count += 1 } }
}

@objcMembers final class SampleFactoryChecks: XCTestCase {
  private func image(width: Int = 96, height: Int = 64,
    type: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, type, nil, &result), kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  private func borrowed(stride: Int = 256, counter: FactoryReleaseCounter = FactoryReleaseCounter()) throws -> CVPixelBuffer {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: stride * 64, alignment: 64)
    memset(bytes, 0, stride * 64)
    let context = Unmanaged.passRetained(counter).toOpaque()
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(nil, 96, 64, kCVPixelFormatType_422YpCbCr10,
      bytes, stride, { context, bytes in
        UnsafeMutableRawPointer(mutating: bytes!).deallocate()
        Unmanaged<FactoryReleaseCounter>.fromOpaque(context!).takeRetainedValue().released()
      }, context, nil, &result)
    guard status == kCVReturnSuccess, let result else {
      bytes.deallocate()
      Unmanaged<FactoryReleaseCounter>.fromOpaque(context).release()
      throw VideoError.message("Cannot allocate borrowed format-cache fixture (\(status)).")
    }
    return result
  }

  private func description(_ sample: CMSampleBuffer) throws -> CMVideoFormatDescription {
    try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
  }

  func testMatchingBuffersReuseFormatButKeepIndependentImagesAndTiming() throws {
    let factory = VideoSampleFactory()
    let firstImage = try image()
    let secondImage = try image()
    let first = try factory.sample(firstImage, at: .zero, duration: VideoContract.fastDuration)
    let secondTime = CMTime(value: 987_654, timescale: 60_000)
    let second = try factory.sample(secondImage, at: secondTime, duration: VideoContract.slowDuration)
    XCTAssertTrue(try description(first) === description(second),
      "Equal formats must reuse the description across distinct captured buffers")
    XCTAssertFalse(first === second)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(first) === firstImage)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(second) === secondImage)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), .zero)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(second), secondTime)
    XCTAssertEqual(CMSampleBufferGetDuration(first), VideoContract.fastDuration)
    XCTAssertEqual(CMSampleBufferGetDuration(second), VideoContract.slowDuration)
    XCTAssertFalse(CMSampleBufferGetDecodeTimeStamp(second).isValid)

    factory.reset()
    let third = try factory.sample(secondImage, at: secondTime, duration: VideoContract.fastDuration)
    XCTAssertFalse(try description(third) === description(second), "Reset must release the previously cached description")
    XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(try description(third), imageBuffer: secondImage))
  }

  func testColorChromaAndApertureChangesAndRemovalInvalidateCachedFormat() throws {
    let apertureA = [kCVImageBufferCleanApertureWidthKey: 96, kCVImageBufferCleanApertureHeightKey: 64,
      kCVImageBufferCleanApertureHorizontalOffsetKey: 0, kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary
    let apertureB = [kCVImageBufferCleanApertureWidthKey: 80, kCVImageBufferCleanApertureHeightKey: 50,
      kCVImageBufferCleanApertureHorizontalOffsetKey: 1, kCVImageBufferCleanApertureVerticalOffsetKey: 1] as CFDictionary
    let cases: [(CFString, CFString, CFTypeRef, CFTypeRef)] = [
      (kCVImageBufferYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_2020),
      (kCVImageBufferColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries,
        kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferColorPrimaries_ITU_R_2020),
      (kCVImageBufferTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction,
        kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferTransferFunction_Linear),
      (kCVImageBufferChromaLocationTopFieldKey, kCMFormatDescriptionExtension_ChromaLocationTopField,
        kCVImageBufferChromaLocation_Left, kCVImageBufferChromaLocation_Center),
      (kCVImageBufferCleanApertureKey, kCMFormatDescriptionExtension_CleanAperture, apertureA, apertureB),
    ]
    for (imageKey, formatKey, firstValue, secondValue) in cases {
      let factory = VideoSampleFactory()
      let source = try image()
      let absent = try factory.sample(source, at: .zero, duration: VideoContract.fastDuration)
      CVBufferSetAttachment(source, imageKey, firstValue, .shouldPropagate)
      let added = try factory.sample(source, at: .zero, duration: VideoContract.fastDuration)
      XCTAssertFalse(try description(absent) === description(added), "Adding \(imageKey) must invalidate cached absence")
      CVBufferSetAttachment(source, imageKey, secondValue, .shouldPropagate)
      let changed = try factory.sample(source, at: .zero, duration: VideoContract.fastDuration)
      let changedFormat = try description(changed)
      XCTAssertFalse(try description(added) === changedFormat, "Changing \(imageKey) must invalidate the prior value")
      XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(changedFormat, imageBuffer: source))
      XCTAssertTrue(CFEqual(try XCTUnwrap(CMFormatDescriptionGetExtension(changedFormat, extensionKey: formatKey)), secondValue))
      CVBufferRemoveAttachment(source, imageKey)
      let removed = try factory.sample(source, at: .zero, duration: VideoContract.fastDuration)
      XCTAssertFalse(changedFormat === (try description(removed)), "Removing \(imageKey) must not leave stale color/geometry metadata")
      XCTAssertNil(CMFormatDescriptionGetExtension(try description(removed), extensionKey: formatKey))
    }
  }

  func testGeometryPixelFormatAndPackedStrideChangesInvalidateCache() throws {
    let factory = VideoSampleFactory()
    var formats = [CMVideoFormatDescription]()
    for source in [try image(), try image(width: 112), try image(height: 66),
      try image(type: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)] {
      let sample = try factory.sample(source, at: .zero, duration: VideoContract.fastDuration)
      let format = try description(sample)
      XCTAssertFalse(formats.contains { $0 === format })
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, Int32(CVPixelBufferGetWidth(source)))
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, Int32(CVPixelBufferGetHeight(source)))
      XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), CVPixelBufferGetPixelFormatType(source))
      formats.append(format)
    }
    let compact = try borrowed()
    let padded = try borrowed(stride: 320)
    let compactFormat = try description(factory.sample(compact, at: .zero, duration: VideoContract.fastDuration))
    let paddedFormat = try description(factory.sample(padded, at: .zero, duration: VideoContract.fastDuration))
    XCTAssertFalse(compactFormat === paddedFormat)
    XCTAssertEqual((CMFormatDescriptionGetExtension(compactFormat,
      extensionKey: kCMFormatDescriptionExtension_BytesPerRow) as? NSNumber)?.intValue, 256)
    XCTAssertEqual((CMFormatDescriptionGetExtension(paddedFormat,
      extensionKey: kCMFormatDescriptionExtension_BytesPerRow) as? NSNumber)?.intValue, 320)
    XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(paddedFormat, imageBuffer: padded))
  }

  func testFactoryDoesNotRetainBorrowedImageAfterSamplesRelease() throws {
    let counter = FactoryReleaseCounter()
    let factory = VideoSampleFactory()
    try autoreleasepool {
      var source: CVPixelBuffer? = try borrowed(counter: counter)
      var sample: CMSampleBuffer? = try factory.sample(XCTUnwrap(source), at: .zero, duration: VideoContract.fastDuration)
      source = nil
      XCTAssertEqual(counter.releases, 0, "The returned sample must own its image")
      XCTAssertNotNil(CMSampleBufferGetImageBuffer(try XCTUnwrap(sample)))
      sample = nil
    }
    XCTAssertEqual(counter.releases, 1,
      "Caching a format must not pin the native capture allocation after all samples release")
    factory.reset()
    XCTAssertEqual(counter.releases, 1)
  }
}

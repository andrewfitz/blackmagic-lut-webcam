import CoreMedia
import CoreVideo
import Darwin
import Foundation
import XCTest

private final class RawCopyAllocation: @unchecked Sendable {
  let base: UnsafeMutableRawPointer
  let length: Int
  private let lock = NSLock()
  private var count = 0

  init(base: UnsafeMutableRawPointer, length: Int) { self.base = base; self.length = length }
  var releases: Int { lock.withLock { count } }
  func releaseMapping() {
    lock.withLock {
      count += 1
      if count == 1 { munmap(base, length) }
    }
  }
}

@objcMembers final class GPURawCopyChecks: XCTestCase {
  private func borrowed(extraStride: Int = 0, offset: Int = 0) throws -> (CVPixelBuffer, RawCopyAllocation) {
    let width = 3840, height = 2160
    let stride = width / 6 * 16 + extraStride
    let pageSize = Int(getpagesize())
    let length = ((stride * height + offset + pageSize - 1) / pageSize) * pageSize
    guard let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
      mapping != MAP_FAILED else { throw VideoError.message("Cannot mmap raw GPU-copy fixture.") }
    let allocation = RawCopyAllocation(base: mapping, length: length)
    let bytes = mapping.advanced(by: offset)
    memset(mapping, 0xDA, length)
    for row in 0..<height {
      let words = bytes.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
      for word in 0..<(width / 6 * 4) { words[word] = pattern(row: row, word: word) }
    }
    let context = Unmanaged.passRetained(allocation).toOpaque()
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(nil, width, height, kCVPixelFormatType_422YpCbCr10,
      bytes, stride, { context, _ in
        Unmanaged<RawCopyAllocation>.fromOpaque(context!).takeRetainedValue().releaseMapping()
      }, context, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      Unmanaged<RawCopyAllocation>.fromOpaque(context).release()
      allocation.releaseMapping()
      throw VideoError.message("Cannot create raw GPU-copy fixture (\(status)).")
    }
    XCTAssertNil(CVPixelBufferGetIOSurface(image))
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    return (image, allocation)
  }

  private func destination() throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    return try XCTUnwrap(image)
  }

  private func pattern(row: Int, word: Int) -> UInt32 {
    // Include the unused high bits: transport must preserve the packed bytes,
    // rather than decode/re-encode or reduce the precision of any component.
    UInt32((row * 65_537 + word * 97) & 0x3FFF_FFFF) | (UInt32(row & 3) << 30)
  }

  private func assertEveryPackedWord(_ image: CVPixelBuffer) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
    let stride = CVPixelBufferGetBytesPerRow(image)
    var mismatchCount = 0
    var firstMismatch: (Int, Int)?
    for row in 0..<2160 {
      let words = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
      for word in 0..<(3840 / 6 * 4) {
        if words[word] != pattern(row: row, word: word) {
          mismatchCount += 1
          if firstMismatch == nil { firstMismatch = (row, word) }
        }
      }
    }
    XCTAssertEqual(mismatchCount, 0, "Every packed word must remain exact; first mismatch=\(String(describing: firstMismatch))")
  }

  func testPageAlignedFourKTransportUsesGPUAndPreservesEveryWord() throws {
    let copier = try XCTUnwrap(GPURawFrameCopy(), "Unified-memory Metal GPU required on this target Mac")
    let (input, allocation) = try borrowed()
    let output = try destination()
    XCTAssertEqual(CVPixelBufferGetBytesPerRow(input), CVPixelBufferGetBytesPerRow(output))
    XCTAssertTrue(try copier.copy(input, to: output), "Eligible borrowed v210 must actually use the GPU copy path")
    XCTAssertEqual(allocation.releases, 0)
    try assertEveryPackedWord(input)
    try assertEveryPackedWord(output)
    XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_422YpCbCr10)
  }

  func testGPUCopyDoesNotPinBorrowedAllocationAfterCompletion() throws {
    let copier = try XCTUnwrap(GPURawFrameCopy())
    var record: RawCopyAllocation?
    try autoreleasepool {
      let fixture = try borrowed()
      record = fixture.1
      let output = try destination()
      XCTAssertTrue(try copier.copy(fixture.0, to: output))
      XCTAssertEqual(fixture.1.releases, 0, "Caller still owns the borrowed source after GPU completion")
      try assertEveryPackedWord(output)
    }
    XCTAssertEqual(try XCTUnwrap(record).releases, 1,
      "Completed raw GPU copy must not keep the native frame alive through its command queue")
  }

  func testUnsupportedLayoutsFallBackWithoutChangingRawMediaOrMetadata() throws {
    let copier = try XCTUnwrap(GPURawFrameCopy())
    for (extraStride, offset) in [(64, 0), (0, 4)] {
      try autoreleasepool {
        let (input, _) = try borrowed(extraStride: extraStride, offset: offset)
        let output = try destination()
        XCTAssertFalse(try copier.copy(input, to: output),
          "Padded rows or an unaligned pointer must select validated fallback")
        let source = try VideoContract.sample(input, at: CMTime(value: 123_456, timescale: 60_000),
          duration: VideoContract.fastDuration)
        CMSetAttachment(source, key: "RawCopyFixture" as CFString, value: "preserved" as CFString,
          attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let staged = try XCTUnwrap(CameraFrameStager().stage(source))
        let stagedImage = try XCTUnwrap(CMSampleBufferGetImageBuffer(staged))
        try assertEveryPackedWord(input)
        try assertEveryPackedWord(stagedImage)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(stagedImage))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(staged), CMSampleBufferGetPresentationTimeStamp(source))
        XCTAssertEqual(CMSampleBufferGetDuration(staged), CMSampleBufferGetDuration(source))
        XCTAssertEqual(CMGetAttachment(staged, key: "RawCopyFixture" as CFString, attachmentModeOut: nil) as? String, "preserved")
        XCTAssertEqual(CVBufferCopyAttachment(stagedImage, kCVImageBufferYCbCrMatrixKey, nil) as? String,
          kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        XCTAssertEqual((CMFormatDescriptionGetExtension(try XCTUnwrap(CMSampleBufferGetFormatDescription(staged)),
          extensionKey: kCMFormatDescriptionExtension_BytesPerRow) as? NSNumber)?.intValue,
          CVPixelBufferGetBytesPerRow(stagedImage))
      }
    }
  }
}

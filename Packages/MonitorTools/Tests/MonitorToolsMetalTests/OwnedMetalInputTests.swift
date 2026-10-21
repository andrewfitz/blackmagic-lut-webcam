import CoreVideo
import Darwin
import Foundation
import IOSurface
@preconcurrency import Metal
import XCTest

@testable import MonitorToolsMetal

final class OwnedMetalInputTests: XCTestCase {
  private let attachmentKey = "OwnedMetalInputTests.owner" as CFString

  // Catches returning a copied upload, releasing the owner early, or modifying source bytes.
  func testGPUReadsOwnedBytesWithoutCopyAndRetainsOwnerUntilBufferRelease() throws {
    let device = try unifiedDevice()
    weak var weakOwner: Owner?
    weak var weakBuffer: AnyObject?
    var input: MTLBuffer?
    var expected: Data!
    try autoreleasepool {
      let pixelBuffer = try packedBuffer()
      let owner = Owner()
      weakOwner = owner
      CVBufferSetAttachment(pixelBuffer, attachmentKey, owner, .shouldNotPropagate)
      let bytes = CVPixelBufferGetDataSize(pixelBuffer)
      XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
      for i in 0..<bytes { base.storeBytes(of: UInt8(truncatingIfNeeded: i * 37 + 11), toByteOffset: i, as: UInt8.self) }
      expected = Data(bytes: base, count: bytes)
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      input = try XCTUnwrap(OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device, requiredLength: bytes))
      weakBuffer = input
      XCTAssertEqual(input!.contents(), base)
      let output = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
      let queue = try XCTUnwrap(device.makeCommandQueue())
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
      blit.copy(from: input!, sourceOffset: 0, to: output, destinationOffset: 0, size: bytes)
      blit.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
      XCTAssertEqual(Data(bytes: output.contents(), count: bytes), expected)
      XCTAssertEqual(Data(bytes: input!.contents(), count: bytes), expected)
    }
    autoreleasepool {
      XCTAssertNotNil(weakOwner, "Metal resource must retain pixel-buffer attachment and owner")
      XCTAssertEqual(Data(bytes: input!.contents(), count: input!.length), expected)
    }
    autoreleasepool { input = nil }
    XCTAssertNil(weakBuffer, "Metal resource should have no remaining references")
    XCTAssertNil(weakOwner, "Releasing Metal resource must release the retained pixel buffer")
  }

  // Catches rounding beyond CVPixelBufferGetDataSize or refusing an exact page boundary.
  func testPageBoundariesStayInsidePixelBufferStorage() throws {
    let device = try unifiedDevice()
    let page = Int(getpagesize())
    let exact = try packedBuffer(stride: page, height: 1)
    XCTAssertEqual(CVPixelBufferGetDataSize(exact), page)
    XCTAssertEqual(OwnedMetalInput.make(pixelBuffer: exact, device: device, requiredLength: page)?.length, page)
    let short = try packedBuffer(stride: page - 64, height: 1)
    XCTAssertNil(OwnedMetalInput.make(pixelBuffer: short, device: device, requiredLength: page - 64))
    let over = try packedBuffer(stride: page + 64, height: 1)
    XCTAssertNil(OwnedMetalInput.make(pixelBuffer: over, device: device, requiredLength: page + 64))
  }

  // Catches unsafe binds on unaligned storage and unchecked signed/round-up overflow.
  func testInvalidRequestsAndUnalignedBaseFallBack() throws {
    let device = try unifiedDevice()
    let pixelBuffer = try packedBuffer()
    for length in [-1, 0, 1, CVPixelBufferGetDataSize(pixelBuffer) + 1, Int.max] {
      XCTAssertNil(OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device, requiredLength: length))
    }
    let unaligned = try packedBuffer(offset: 1)
    XCTAssertNil(OwnedMetalInput.make(pixelBuffer: unaligned, device: device, requiredLength: CVPixelBufferGetDataSize(unaligned)))
  }

  // Catches trusting Core Video's declared span without checking actual VM readability.
  func testDeclaredStorageCrossingUnreadableVMRegionFallsBack() throws {
    let device = try unifiedDevice()
    let page = Int(getpagesize())
    let mapping = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
    XCTAssertNotEqual(mapping, MAP_FAILED)
    let base = try XCTUnwrap(mapping)
    XCTAssertEqual(mprotect(base.advanced(by: page), page, PROT_NONE), 0)
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(nil, 16, 2, kCVPixelFormatType_32BGRA,
      base, page, { context, _ in
        if let context { munmap(context, Int(getpagesize()) * 2) }
      }, base, nil, &result)
    if status != kCVReturnSuccess { munmap(base, page * 2) }
    XCTAssertEqual(status, kCVReturnSuccess)
    let pixelBuffer = try XCTUnwrap(result)
    XCTAssertNil(OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device, requiredLength: page * 2))
  }

  // Catches binding metadata headers, unequal strides, or a gap between Y and UV as image bytes.
  func testNoncanonicalPlanarStorageFallsBack() throws {
    let device = try unifiedDevice()
    for (gap, uvStride) in [(64, 256), (0, 320)] {
      let pixelBuffer = try planarBuffer(gap: gap, uvStride: uvStride)
      XCTAssertNil(OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device, requiredLength: 256 * 192))
    }
  }

  // Catches accepting only BGRA even when canonical supported native storage is safe.
  func testPageAlignedPackedV210AndCanonicalPlanarStorageBind() throws {
    let device = try unifiedDevice()
    let packed = try packedBuffer(format: kCVPixelFormatType_422YpCbCr10)
    XCTAssertNotNil(OwnedMetalInput.make(pixelBuffer: packed, device: device,
      requiredLength: Int(getpagesize())))
    let planar = try planarBuffer(gap: 0, uvStride: 256)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(planar, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(planar, .readOnly) }
    XCTAssertEqual(CVPixelBufferGetBaseAddress(planar), CVPixelBufferGetBaseAddressOfPlane(planar, 0))
    XCTAssertNotNil(OwnedMetalInput.make(pixelBuffer: planar, device: device, requiredLength: 256 * 192))
  }

  // Catches treating an arbitrary packed format as one of the shader's native layouts.
  func testUnsupportedPackedFormatFallsBack() throws {
    let device = try unifiedDevice()
    let pixelBuffer = try packedBuffer(format: kCVPixelFormatType_32ARGB)
    XCTAssertNil(OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device,
      requiredLength: CVPixelBufferGetDataSize(pixelBuffer)))
  }

  // Catches rejecting valid native input formats or trusting an IOSurface's allocation size
  // when Core Video exposes fewer bytes. Printed facts also characterize real pool layouts.
  func testNativeIOSurfaceLayoutsUseOnlyEligibleStorage() throws {
    let device = try unifiedDevice()
    for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr10,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange] {
      var result: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, format,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &result), kCVReturnSuccess)
      let pixelBuffer = try XCTUnwrap(result)
      XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly), kCVReturnSuccess)
      defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
      let planar = CVPixelBufferIsPlanar(pixelBuffer)
      let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
      let yBytes = stride * 1080
      let bytes = yBytes + (planar ? stride * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) : 0)
      let page = Int(getpagesize())
      let rounded = ((bytes + page - 1) / page) * page
      let contiguous = !planar || (CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) == base
        && CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) == stride
        && CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) == base.advanced(by: yBytes))
      let eligible = contiguous && UInt(bitPattern: base).isMultiple(of: UInt(page)) && rounded <= CVPixelBufferGetDataSize(pixelBuffer)
      let binding = OwnedMetalInput.make(pixelBuffer: pixelBuffer, device: device, requiredLength: bytes)
      print("OwnedMetalInput layout format=\(format) stride=\(stride) data=\(CVPixelBufferGetDataSize(pixelBuffer)) rounded=\(rounded) surface=\(CVPixelBufferGetIOSurface(pixelBuffer).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? 0) contiguous=\(contiguous) bound=\(binding != nil)")
      if eligible { XCTAssertNotNil(binding, "Eligible native format \(format)") }
      else { XCTAssertNil(binding, "Unsafe native format \(format) must fall back") }
    }
  }

  private func unifiedDevice() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
      throw XCTSkip("Unified-memory Metal device unavailable")
    }
    return device
  }

  private func packedBuffer(stride: Int = Int(getpagesize()), height: Int = 1, offset: Int = 0,
    format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
    var allocation: UnsafeMutableRawPointer?
    XCTAssertEqual(posix_memalign(&allocation, Int(getpagesize()), stride * height + offset), 0)
    let base = try XCTUnwrap(allocation)
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(nil, 16, height, format,
      base.advanced(by: offset), stride, { context, _ in free(context) }, base, nil, &result)
    if status != kCVReturnSuccess { free(base) }
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  private func planarBuffer(gap: Int, uvStride: Int) throws -> CVPixelBuffer {
    let yBytes = 256 * 128
    let bytes = yBytes + gap + uvStride * 64
    var allocation: UnsafeMutableRawPointer?
    XCTAssertEqual(posix_memalign(&allocation, Int(getpagesize()), bytes), 0)
    let base = try XCTUnwrap(allocation)
    memset(base, 0, bytes)
    var result: CVPixelBuffer?
    var addresses: [UnsafeMutableRawPointer?] = [base, base.advanced(by: yBytes + gap)]
    var widths = [256, 128]
    var heights = [128, 64]
    var strides = [256, uvStride]
    let status = CVPixelBufferCreateWithPlanarBytes(nil, 256, 128,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, base, bytes, 2, &addresses,
      &widths, &heights, &strides, { context, _, _, _, _ in free(context) }, base, nil, &result)
    if status != kCVReturnSuccess { free(base) }
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  private final class Owner: NSObject {}
}

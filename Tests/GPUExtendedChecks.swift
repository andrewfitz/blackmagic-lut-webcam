import CoreVideo
import Darwin
import Foundation
import Metal
import XCTest

private final class BorrowedGPUAllocation: @unchecked Sendable {
  let base: UnsafeMutableRawPointer
  let length: Int
  let released: @Sendable () -> Void

  init(base: UnsafeMutableRawPointer, length: Int, released: @escaping @Sendable () -> Void) {
    self.base = base
    self.length = length
    self.released = released
  }

  deinit { munmap(base, length); released() }
}

private final class GPUReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var releases = 0
  var count: Int { lock.withLock { releases } }
  func increment() { lock.withLock { releases += 1 } }
}

@objcMembers final class GPUExtendedChecks: XCTestCase {
  private func input(packed: Bool = false, width: Int = 3840, height: Int = 2160,
    luma: (Int, Int) -> UInt16 = { _, _ in 400 },
    cb: (Int, Int) -> UInt16 = { _, _ in 512 },
    cr: (Int, Int) -> UInt16 = { _, _ in 512 }) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height,
      packed ? kCVPixelFormatType_422YpCbCr10 : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &result)
    XCTAssertEqual(status, kCVReturnSuccess)
    let buffer = try XCTUnwrap(result)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if packed {
      let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
      let words = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
      for y in 0..<height {
        for x in Swift.stride(from: 0, to: width, by: 6) {
          let offset = y * stride + x / 6 * 4
          let pair = x / 2
          words[offset] = UInt32(cb(pair, y)) | (UInt32(luma(x, y)) << 10) | (UInt32(cr(pair, y)) << 20)
          words[offset + 1] = UInt32(luma(x + 1, y)) | (UInt32(cb(pair + 1, y)) << 10) | (UInt32(luma(x + 2, y)) << 20)
          words[offset + 2] = UInt32(cr(pair + 1, y)) | (UInt32(luma(x + 3, y)) << 10) | (UInt32(cb(pair + 2, y)) << 20)
          words[offset + 3] = UInt32(luma(x + 4, y)) | (UInt32(cr(pair + 2, y)) << 10) | (UInt32(luma(x + 5, y)) << 20)
        }
      }
    } else {
      let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
      let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
      let yWords = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
      let uvWords = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
      for y in 0..<height {
        for x in 0..<width { yWords[y * yStride + x] = luma(x, y) << 6 }
        for pair in 0..<(width / 2) {
          uvWords[y * uvStride + pair * 2] = cb(pair, y) << 6
          uvWords[y * uvStride + pair * 2 + 1] = cr(pair, y) << 6
        }
      }
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return buffer
  }

  private func read10(_ buffer: CVPixelBuffer, plane: Int, x: Int, y: Int = 0) -> UInt16 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
    return CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)[y * stride + x] >> 6
  }

  private func borrowedInput(offset: Int = 0, stride: Int = 10240, splitVMRegion: Bool = false,
    released: @escaping @Sendable () -> Void = {}) throws -> CVPixelBuffer {
    let page = Int(getpagesize())
    let length = ((stride * 2160 + offset + page - 1) / page) * page
    guard let allocation = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
      allocation != MAP_FAILED else { throw VideoError.message("Cannot allocate synthetic borrowed capture.") }
    let owner = BorrowedGPUAllocation(base: allocation, length: length, released: released)
    let bytes = allocation.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
    for y in 0..<2160 {
      func luma(_ x: Int) -> UInt32 { UInt32(64 + x * 876 / 3839) }
      for x in Swift.stride(from: 0, to: 3840, by: 6) {
        let o = y * stride / 4 + x / 6 * 4
        bytes[o] = 512 | (luma(x) << 10) | (512 << 20)
        bytes[o + 1] = luma(x + 1) | (512 << 10) | (luma(x + 2) << 20)
        bytes[o + 2] = 512 | (luma(x + 3) << 10) | (512 << 20)
        bytes[o + 3] = luma(x + 4) | (512 << 10) | (luma(x + 5) << 20)
      }
    }
    if splitVMRegion {
      // Both halves stay readable, but Metal forbids wrapping their combined
      // range once a different protection creates a second VM region.
      XCTAssertEqual(mprotect(allocation.advanced(by: length / 2 / page * page), page, PROT_READ), 0)
    }
    var buffer: CVPixelBuffer?
    let context = Unmanaged.passRetained(owner).toOpaque()
    let status = CVPixelBufferCreateWithBytes(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      allocation.advanced(by: offset), stride,
      { context, _ in Unmanaged<BorrowedGPUAllocation>.fromOpaque(context!).release() }, context, nil, &buffer)
    if status != kCVReturnSuccess { Unmanaged<BorrowedGPUAllocation>.fromOpaque(context).release() }
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(buffer)
  }

  func testPackedAndPlanarAgreeForEveryLaneAndRowStride() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    let y: (Int, Int) -> UInt16 = { x, row in UInt16(200 + (x * 7 + row * 11) % 600) }
    let cb: (Int, Int) -> UInt16 = { pair, row in UInt16(350 + (pair * 13 + row * 17) % 250) }
    let cr: (Int, Int) -> UInt16 = { pair, row in UInt16(410 + (pair * 19 + row * 23) % 200) }
    let packed = try processor.process(input(packed: true, luma: y, cb: cb, cr: cr), configuration: config)
    let planar = try processor.process(input(luma: y, cb: cb, cr: cr), configuration: config)
    CVPixelBufferLockBaseAddress(packed, .readOnly)
    CVPixelBufferLockBaseAddress(planar, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(packed, .readOnly)
      CVPixelBufferUnlockBaseAddress(planar, .readOnly)
    }
    for plane in 0..<2 {
      let packedStride = CVPixelBufferGetBytesPerRowOfPlane(packed, plane) / 2
      let planarStride = CVPixelBufferGetBytesPerRowOfPlane(planar, plane) / 2
      let a = CVPixelBufferGetBaseAddressOfPlane(packed, plane)!.assumingMemoryBound(to: UInt16.self)
      let b = CVPixelBufferGetBaseAddressOfPlane(planar, plane)!.assumingMemoryBound(to: UInt16.self)
      for row in [0, 1, 1091, 2159] {
        for x in 0..<3840 {
          XCTAssertEqual(Double(a[row * packedStride + x] >> 6), Double(b[row * planarStride + x] >> 6), accuracy: 1,
            "v210/planar mismatch at plane \(plane), row \(row), column \(x)")
        }
      }
    }
  }

  func testChromaLocationHonoredAndOutputCentered() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    for packed in [false, true] {
      let source = try input(packed: packed, cb: { pair, _ in pair < 10 ? 512 : 800 })
      let left = try processor.process(source, configuration: config)
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
      let center = try processor.process(source, configuration: config)
      XCTAssertEqual(Double(read10(left, plane: 1, x: 18)), 584, accuracy: 1)
      XCTAssertEqual(Double(read10(center, plane: 1, x: 18)), 548, accuracy: 1)
      XCTAssertEqual(CVBufferCopyAttachment(left, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
        kCVImageBufferChromaLocation_Center as String)
    }
  }

  func testRGBOrderingAndDomainClipping() throws {
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(b) \(r) \(g)\n" } } }
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: text))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    // Independent Rec.709 reference: encode source RGB, then domain-normalize,
    // clamp and permute B->R, R->G, G->B through the LUT.
    for rgb in [SIMD3<Double>(0.4, 0.6, 0.3), SIMD3<Double>(0.1, 0.7, 0.85)] {
      let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
      let cb = (rgb.z - y) / (2 * (1 - 0.0722))
      let cr = (rgb.x - y) / (2 * (1 - 0.2126))
      let source = try input(luma: { _, _ in UInt16((64 + 876 * y).rounded()) },
        cb: { _, _ in UInt16((512 + 896 * cb).rounded()) }, cr: { _, _ in UInt16((512 + 896 * cr).rounded()) })
      let mapped = SIMD3<Double>(min(1, max(0, (rgb.z - 0.25) / 0.5)),
        min(1, max(0, (rgb.x - 0.25) / 0.5)), min(1, max(0, (rgb.y - 0.25) / 0.5)))
      let mappedY = 0.2126 * mapped.x + 0.7152 * mapped.y + 0.0722 * mapped.z
      let output = try processor.process(source, configuration: config)
      XCTAssertEqual(Double(read10(output, plane: 0, x: 100)), 64 + 876 * mappedY, accuracy: 2)
      XCTAssertEqual(Double(read10(output, plane: 1, x: 100)), 512 + 896 * (mapped.z - mappedY) / (2 * (1 - 0.0722)), accuracy: 2)
      XCTAssertEqual(Double(read10(output, plane: 1, x: 101)), 512 + 896 * (mapped.x - mappedY) / (2 * (1 - 0.2126)), accuracy: 2)
    }
  }

  func testLanczosMatchesIndependentScalarReferenceAtEdgesAndImpulse() throws {
    let processor = try LUTProcessor()
    let source = try input(luma: { x, _ in (x == 0 || x == 1919 || x == 3839) ? 940 : 64 })
    let output = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: false))
    func sinc(_ value: Double) -> Double { abs(value) < 1e-8 ? 1 : sin(.pi * value) / (.pi * value) }
    for x in [0, 1, 2, 958, 959, 960, 961, 1917, 1918, 1919] {
      let center = (Double(x) + 0.5) * 2 - 0.5
      var total = 0.0, weights = 0.0
      for sourceX in Int(ceil(center - 6))...Int(floor(center + 6)) {
        let offset = (Double(sourceX) - center) / 2
        let weight = abs(offset) < 3 ? sinc(offset) * sinc(offset / 3) : 0
        let clamped = min(3839, max(0, sourceX))
        total += ([0, 1919, 3839].contains(clamped) ? 1 : 0) * weight
        weights += weight
      }
      XCTAssertEqual(Double(read10(output, plane: 0, x: x)), max(0, min(1023, 64 + 876 * total / weights)), accuracy: 1)
    }
  }

  func testInvalidSourceRejectedEvenWithEffectsOff() throws {
    let processor = try LUTProcessor()
    let config = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    XCTAssertThrowsError(try processor.process(input(width: 1920, height: 1080), configuration: config))
    var wrongFormat: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA, nil, &wrongFormat), kCVReturnSuccess)
    XCTAssertThrowsError(try processor.process(XCTUnwrap(wrongFormat), configuration: config))
  }

  func testReusedPoolDoesNotLeakLUTColorLabelsOntoBypass() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try input()
    var config = PipelineConfiguration(applyLUT: true, downscale: true, convertTo420: true)
    for _ in 0..<8 { _ = try processor.process(source, configuration: config) }
    config.applyLUT = false
    let bypass = try processor.process(source, configuration: config)
    XCTAssertNil(CVBufferCopyAttachment(bypass, kCVImageBufferColorPrimariesKey, nil))
    XCTAssertNil(CVBufferCopyAttachment(bypass, kCVImageBufferTransferFunctionKey, nil))
    XCTAssertEqual(CVBufferCopyAttachment(bypass, kCVImageBufferYCbCrMatrixKey, nil) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
  }

  func testPrewarmPreservesTenBitLUTProcessingAndPoolCapacity() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    try processor.prepare(configuration: config)
    let source = try syntheticRamp()
    let output = try processor.process(source, configuration: config)
    XCTAssertEqual(read10(output, plane: 0, x: 1920), UInt16(64 + 1920 * 876 / 3839))
    var held = [output]
    for _ in 1..<8 { held.append(try processor.process(source, configuration: config)) }
    XCTAssertEqual(held.count, 8, "Prewarm must release all warm frames before native capture starts")
  }

  func testNoCopyMappingOwnsBorrowedFrameThroughGPUCommandCompletion() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let release = expectation(description: "borrowed capture allocation released exactly once")
    let counter = GPUReleaseCounter()
    try autoreleasepool {
      var source: CVPixelBuffer? = try borrowedInput { counter.increment(); release.fulfill() }
      var shared = SharedMetalBuffer.make(pixelBuffer: try XCTUnwrap(source), device: device, readOnly: true)
      XCTAssertNotNil(shared, "Page-aligned single-region capture must bypass CPU memcpy")
      let output = try XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared))
      var command = try XCTUnwrap(queue.makeCommandBuffer()) as MTLCommandBuffer?
      let encoder = try XCTUnwrap(command?.makeBlitCommandEncoder())
      encoder.copy(from: try XCTUnwrap(shared), sourceOffset: 0, to: output, destinationOffset: 0, size: 16)
      encoder.endEncoding()
      source = nil
      shared = nil
      XCTAssertEqual(counter.count, 0, "Encoded GPU work must retain and lock borrowed bytes even after caller release")
      command?.commit()
      command?.waitUntilCompleted()
      XCTAssertEqual(command?.status, .completed)
      XCTAssertEqual(output.contents().load(as: UInt32.self), 512 | (64 << 10) | (512 << 20))
      command = nil
    }
    wait(for: [release], timeout: 2)
    XCTAssertEqual(counter.count, 1)
  }

  func testNoCopyAndFallbackProduceIdenticalTenBitLevelsForEveryPackedLane() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    for (offset, stride, split, expectsNoCopy) in [
      (0, 10240, false, true), (4, 10240, false, false),
      (0, 10244, false, false), (0, 10240, true, false),
    ] {
      let source = try borrowedInput(offset: offset, stride: stride, splitVMRegion: split)
      let shared = SharedMetalBuffer.make(pixelBuffer: source, device: device, readOnly: true)
      XCTAssertEqual(shared != nil, expectsNoCopy)
      let before = processor.packedInputDiagnostics
      let output = try processor.process(source, configuration: config)
      let after = processor.packedInputDiagnostics
      XCTAssertEqual(after.noCopyFrames - before.noCopyFrames, expectsNoCopy ? 1 : 0)
      XCTAssertEqual(after.copiedFrames - before.copiedFrames, expectsNoCopy ? 0 : 1)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let rowStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
      let words = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
      for row in [0, 1, 1091, 2159] {
        for x in 0..<3840 {
          XCTAssertEqual(Double(words[row * rowStride + x] >> 6), Double(64 + x * 876 / 3839), accuracy: 1)
        }
      }
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }

  func testUndersizedPackedStrideRejectedBeforeAnyGPUOrPassthroughUse() throws {
    let processor = try LUTProcessor()
    let source = try borrowedInput(stride: 10236)
    XCTAssertThrowsError(try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)))
    XCTAssertThrowsError(try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)))
    XCTAssertEqual(processor.packedInputDiagnostics.noCopyFrames, 0)
    XCTAssertEqual(processor.packedInputDiagnostics.copiedFrames, 0)
  }

  func testBypassReleasesWorkingAllocationsWithoutInvalidatingPublishedFrame() throws {
    let processor = try LUTProcessor()
    let source = try borrowedInput(offset: 4)
    let processed = PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)
    let published = try processor.process(source, configuration: processed)
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.packedCopyBytes, 0)
    XCTAssertTrue(processor.workingResourceDiagnostics.outputPoolActive)
    func middleLuma() -> UInt8 {
      CVPixelBufferLockBaseAddress(published, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(published, .readOnly) }
      return CVPixelBufferGetBaseAddressOfPlane(published, 0)!.assumingMemoryBound(to: UInt8.self)[960]
    }
    let expected = middleLuma()
    let bypass = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    try processor.prepare(configuration: bypass)
    XCTAssertEqual(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    XCTAssertEqual(processor.workingResourceDiagnostics.packedCopyBytes, 0)
    XCTAssertFalse(processor.workingResourceDiagnostics.outputPoolActive)
    XCTAssertEqual(middleLuma(), expected, "Releasing working memory must preserve an already published IOSurface")
    XCTAssertTrue(try processor.process(source, configuration: bypass) === source)
    let resumed = try processor.process(source, configuration: processed)
    XCTAssertEqual(CVPixelBufferGetWidth(resumed), 1920)
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.floatTextureBytes, 0)
  }

  func testDisablingDownscaleReleasesOnlyScalingTexturesAndPreservesPrecision() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try syntheticRamp()
    _ = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: true, downscale: true, convertTo420: false))
    let scaledBytes = processor.workingResourceDiagnostics.floatTextureBytes
    let full = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false))
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    XCTAssertLessThan(processor.workingResourceDiagnostics.floatTextureBytes, scaledBytes)
    XCTAssertEqual(read10(full, plane: 0, x: 1920), UInt16(64 + 1920 * 876 / 3839))
  }
}

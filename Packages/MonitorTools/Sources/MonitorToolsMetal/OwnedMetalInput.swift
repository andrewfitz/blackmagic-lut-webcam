import CoreVideo
import Darwin
import Metal

/// A command-lifetime, read-only view of an already owned monitor allocation.
/// Callers must never pass a producer buffer or cache the returned binding.
/// `requiredLength` is the complete canonical image span; a nil result requires
/// the caller's ordinary upload path. Page padding must belong to Core Video.
enum OwnedMetalInput {
  static func make(pixelBuffer: CVPixelBuffer, device: MTLDevice, requiredLength: Int) -> MTLBuffer? {
    let pageSize = Int(getpagesize())
    let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
    guard device.hasUnifiedMemory, requiredLength > 0, dataSize > 0,
      requiredLength <= dataSize, pageSize > 0,
      let lease = PixelBufferLease(pixelBuffer),
      let base = CVPixelBufferGetBaseAddress(pixelBuffer),
      UInt(bitPattern: base).isMultiple(of: UInt(pageSize)),
      canonicalLength(pixelBuffer, base: base) == requiredLength
    else { return nil }
    let (padded, overflow) = requiredLength.addingReportingOverflow(pageSize - 1)
    guard !overflow else { return nil }
    let length = (padded / pageSize) * pageSize
    guard length <= dataSize, length <= device.maxBufferLength,
      fitsSingleReadableVMRegion(base: base, length: length)
    else { return nil }
    return device.makeBuffer(bytesNoCopy: base, length: length, options: .storageModeShared) { _, _ in
      // Core Video owns the bytes. Keep its owner and lock, and never free or
      // mutate the allocation when Metal releases this view.
      withExtendedLifetime(lease) {}
    }
  }

  private static func canonicalLength(_ pixelBuffer: CVPixelBuffer, base: UnsafeMutableRawPointer) -> Int? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_422YpCbCr10 {
      guard !CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else { return nil }
      let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
      let minimum: Int
      if format == kCVPixelFormatType_32BGRA {
        let (bytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow else { return nil }
        minimum = bytes
      } else {
        let (paddedWidth, widthOverflow) = width.addingReportingOverflow(5)
        guard !widthOverflow else { return nil }
        let (bytes, overflow) = (paddedWidth / 6).multipliedReportingOverflow(by: 16)
        guard !overflow, stride.isMultiple(of: 4) else { return nil }
        minimum = bytes
      }
      let (length, overflow) = stride.multipliedReportingOverflow(by: height)
      return stride >= minimum && !overflow && length > 0 ? length : nil
    }
    let tenBit: Bool
    let fullChromaHeight: Bool
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      tenBit = false
      fullChromaHeight = false
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      tenBit = true
      fullChromaHeight = false
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
      tenBit = true
      fullChromaHeight = true
    default: return nil
    }
    guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
      width.isMultiple(of: 2),
      CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == width,
      CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == width / 2,
      CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height,
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) == base,
      let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else { return nil }
    let chromaHeight = fullChromaHeight ? height : height / 2 + height % 2
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let (minimum, minimumOverflow) = width.multipliedReportingOverflow(by: tenBit ? 2 : 1)
    let (lumaLength, lumaOverflow) = stride.multipliedReportingOverflow(by: height)
    let (rows, rowsOverflow) = height.addingReportingOverflow(chromaHeight)
    let (length, lengthOverflow) = stride.multipliedReportingOverflow(by: rows)
    guard !minimumOverflow, !lumaOverflow, !rowsOverflow, !lengthOverflow,
      stride >= minimum, stride.isMultiple(of: tenBit ? 2 : 1), length > 0,
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) == stride,
      CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == chromaHeight
    else { return nil }
    let (expectedChroma, addressOverflow) = UInt(bitPattern: base).addingReportingOverflow(UInt(lumaLength))
    guard !addressOverflow, UInt(bitPattern: chromaBase) == expectedChroma else { return nil }
    return length
  }

  private static func fitsSingleReadableVMRegion(base: UnsafeMutableRawPointer, length: Int) -> Bool {
    let start = mach_vm_address_t(UInt(bitPattern: base))
    var regionStart = start
    var regionSize: mach_vm_size_t = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var object = mach_port_t(MACH_PORT_NULL)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        mach_vm_region(mach_task_self_, &regionStart, &regionSize, VM_REGION_BASIC_INFO_64, $0, &count, &object)
      }
    }
    defer { if object != MACH_PORT_NULL { mach_port_deallocate(mach_task_self_, object) } }
    guard status == KERN_SUCCESS, regionStart <= start, regionSize >= start - regionStart,
      mach_vm_size_t(length) <= regionSize - (start - regionStart),
      info.protection & VM_PROT_READ != 0
    else { return false }
    return true
  }

  private final class PixelBufferLease: @unchecked Sendable {
    private let pixelBuffer: CVPixelBuffer
    private var locked = false

    init?(_ pixelBuffer: CVPixelBuffer) {
      self.pixelBuffer = pixelBuffer
      guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
      locked = true
    }

    deinit { if locked { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) } }
  }
}

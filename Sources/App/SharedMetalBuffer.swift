import CoreVideo
import Darwin
import Metal

// A bounded, bit-exact view of an existing packed capture allocation. Metal
// requires page-aligned bytes and length wholly inside one VM region. Never
// round into padding that the pixel buffer does not own or free borrowed bytes.
enum SharedMetalBuffer {
  static func make(pixelBuffer: CVPixelBuffer, device: MTLDevice, readOnly: Bool) -> MTLBuffer? {
    guard device.hasUnifiedMemory,
      CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_422YpCbCr10,
      !CVPixelBufferIsPlanar(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let (paddedWidth, widthOverflow) = width.addingReportingOverflow(5)
    let (minimumStride, strideOverflow) = (paddedWidth / 6).multipliedReportingOverflow(by: 16)
    let (length, lengthOverflow) = stride.multipliedReportingOverflow(by: height)
    let pageSize = Int(getpagesize())
    guard width > 0, height > 0, !widthOverflow, !strideOverflow, !lengthOverflow,
      stride >= minimumStride, stride.isMultiple(of: 4), length > 0,
      length <= device.maxBufferLength, length.isMultiple(of: pageSize),
      let lease = PixelBufferLease(pixelBuffer, readOnly: readOnly),
      let base = CVPixelBufferGetBaseAddress(pixelBuffer),
      UInt(bitPattern: base).isMultiple(of: UInt(pageSize)),
      fitsSingleVMRegion(base: base, length: length, writable: !readOnly) else { return nil }
    return device.makeBuffer(bytesNoCopy: base, length: length, options: .storageModeShared) { _, _ in
      // The capture allocation belongs to Core Video/DeckLink. Retain its
      // owner and lock for the Metal resource's full lifetime, then release it.
      withExtendedLifetime(lease) {}
    }
  }

  private static func fitsSingleVMRegion(base: UnsafeMutableRawPointer, length: Int, writable: Bool) -> Bool {
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
      info.protection & VM_PROT_READ != 0 else { return false }
    return !writable || info.protection & VM_PROT_WRITE != 0
  }

  private final class PixelBufferLease: @unchecked Sendable {
    private let pixelBuffer: CVPixelBuffer
    private let flags: CVPixelBufferLockFlags
    private var locked = false

    init?(_ pixelBuffer: CVPixelBuffer, readOnly: Bool) {
      self.pixelBuffer = pixelBuffer
      flags = readOnly ? .readOnly : []
      guard CVPixelBufferLockBaseAddress(pixelBuffer, flags) == kCVReturnSuccess else { return nil }
      locked = true
    }

    deinit { if locked { CVPixelBufferUnlockBaseAddress(pixelBuffer, flags) } }
  }
}

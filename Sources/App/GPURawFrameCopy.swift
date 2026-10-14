import CoreVideo
import Darwin
import Metal

// Bit-exact raw transport copy, with no decode, color transform or quantization.
// Shared buffers retain/lock both pixel buffers until Metal releases them.
final class GPURawFrameCopy {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
#if CAPTURE_LIFECYCLE_TESTS
  struct Timing {
    var mode = "cpuFallback"
    var wallMS = 0.0
    var cpuMS = 0.0
    var gpuMS = 0.0
    var initializationWallMS = 0.0
    var initializationCPUMS = 0.0
  }
  private(set) var lastTiming = Timing()
#endif

  init?() {
#if CAPTURE_LIFECYCLE_TESTS
    let wallStarted = ProcessInfo.processInfo.systemUptime
    let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
#endif
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
      let queue = device.makeCommandQueue() else { return nil }
    self.device = device
    self.queue = queue
#if CAPTURE_LIFECYCLE_TESTS
    lastTiming.initializationWallMS = (ProcessInfo.processInfo.systemUptime - wallStarted) * 1000
    lastTiming.initializationCPUMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted) / 1_000_000
#endif
  }

  func copy(_ input: CVPixelBuffer, to output: CVPixelBuffer) throws -> Bool {
#if CAPTURE_LIFECYCLE_TESTS
    let wallStarted = ProcessInfo.processInfo.systemUptime
    let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    lastTiming.mode = "cpuFallback"
    lastTiming.gpuMS = 0
    defer {
      lastTiming.wallMS = (ProcessInfo.processInfo.systemUptime - wallStarted) * 1000
      lastTiming.cpuMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted) / 1_000_000
    }
#endif
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let stride = CVPixelBufferGetBytesPerRow(input)
    // The fast path copies only active media bytes. Unsupported/padded layouts
    // use the existing validated CPU row copy, including deterministic padding.
    guard CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_422YpCbCr10,
      CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_422YpCbCr10,
      width == CVPixelBufferGetWidth(output), height == CVPixelBufferGetHeight(output),
      stride == ((width + 5) / 6) * 16,
      stride == CVPixelBufferGetBytesPerRow(output),
      let source = SharedMetalBuffer.make(pixelBuffer: input, device: device, readOnly: true),
      let destination = SharedMetalBuffer.make(pixelBuffer: output, device: device, readOnly: false),
      let command = queue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder() else { return false }
    command.label = "Bit-exact raw video transport copy"
#if CAPTURE_LIFECYCLE_TESTS
    lastTiming.mode = "gpuBlit"
#endif
    encoder.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0,
      size: stride * height)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
#if CAPTURE_LIFECYCLE_TESTS
    lastTiming.gpuMS = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
#endif
    withExtendedLifetime((source, destination)) {}
    guard command.status == .completed else {
      throw VideoError.message(command.error?.localizedDescription ?? "GPU raw video copy failed.")
    }
    return true
  }
}

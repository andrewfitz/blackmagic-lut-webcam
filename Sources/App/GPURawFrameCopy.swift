import CoreVideo
import Metal

// Bit-exact raw transport copy, with no decode, color transform or quantization.
// Shared buffers retain/lock both pixel buffers until Metal releases them.
final class GPURawFrameCopy {
  private let device: MTLDevice
  private let queue: MTLCommandQueue

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
      let queue = device.makeCommandQueue() else { return nil }
    self.device = device
    self.queue = queue
  }

  func copy(_ input: CVPixelBuffer, to output: CVPixelBuffer) throws -> Bool {
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
    encoder.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0,
      size: stride * height)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime((source, destination)) {}
    guard command.status == .completed else {
      throw VideoError.message(command.error?.localizedDescription ?? "GPU raw video copy failed.")
    }
    return true
  }
}

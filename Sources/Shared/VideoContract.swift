import CoreMedia
import CoreVideo
import Foundation

enum VideoContract {
  static let cameraName = "UltraStudio LUT"
  static let sinkName = "UltraStudio LUT Input"
  static let deviceUID = "org.ultrastudiolut.camera.device"
  static let extensionID = "org.ultrastudiolut.app.camera"
  static let slowDuration = CMTime(value: 1001, timescale: 30_000)
  static let fastDuration = CMTime(value: 1001, timescale: 60_000)
  static let tenBit422: [OSType] = [
    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    kCVPixelFormatType_422YpCbCr10,
  ]

  static func fourCC(_ value: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
    guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08X", value) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
  }

  static func formatDescription(width: Int, height: Int, pixelFormat: OSType) throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: pixelFormat,
      width: Int32(width), height: Int32(height),
      extensions: [
        kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
      ] as CFDictionary, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw VideoError.message("Could not create video format (\(status)).") }
    return format
  }

  static func sample(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    var status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw VideoError.message("Invalid pixel buffer (\(status)).") }
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw VideoError.message("Could not create sample (\(status)).") }
    return sample
  }
}

struct PipelineConfiguration: Equatable, Sendable {
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var inputFast = true

  var width: Int { downscale ? 1920 : 3840 }
  var height: Int { downscale ? 1080 : 2160 }
  var pixelFormat: OSType {
    convertTo420 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
  }
  var duration: CMTime {
    inputFast && !reduceFrameRate ? VideoContract.fastDuration : VideoContract.slowDuration
  }
  var untouched: Bool { !applyLUT && !downscale && !convertTo420 }
  var outputLabel: String {
    "\(width) × \(height) · \(convertTo420 ? "4:2:0 8-bit" : "4:2:2 10-bit") · \(duration == VideoContract.fastDuration ? "59.94" : "29.97") fps"
  }
}

enum VideoError: LocalizedError {
  case message(String)
  case outputBackPressure
  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    case .outputBackPressure: return "Output buffers are busy; dropping this frame."
    }
  }
}

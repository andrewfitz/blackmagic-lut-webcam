import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Errors raised while preparing a ProRes recording input.
public enum ProResRecordingError: LocalizedError, Equatable {
  case invalidDimensions(width: Int, height: Int)
  case dimensionsTooLarge(width: Int, height: Int, maximum: Int)
  case dimensionsMustBeEven(width: Int, height: Int)
  case unsupportedPixelFormat(OSType)
  case unsupportedFrameRate(CMTime)
  case invalidTimecodeFrame(Int64)
  case invalidTimecodeTimestamp
  case invalidTimecodeDuration
  case timecodeFormatCreationFailed(OSStatus)
  case sampleCreationFailed(OSStatus)
  case encoderUnavailable(codec: String, width: Int, height: Int, reason: String)
  case encoderCapabilityQueryFailed(codec: String, status: OSStatus)

  public var errorDescription: String? {
    switch self {
    case let .invalidDimensions(width, height):
      return "ProRes 422 requires positive video dimensions (got \(width) × \(height))."
    case let .dimensionsTooLarge(width, height, maximum):
      return "ProRes 422 dimensions \(width) × \(height) exceed the supported \(maximum)-pixel limit."
    case let .dimensionsMustBeEven(width, height):
      return "ProRes 422 4:2:2 requires even dimensions (got \(width) × \(height))."
    case let .unsupportedPixelFormat(pixelFormat):
      return "ProRes 422 10-bit requires a 10-bit 4:2:2 CVPixelBuffer (got \(Self.fourCC(pixelFormat)))."
    case let .unsupportedFrameRate(duration):
      return "Unsupported ProRes frame rate; source frame duration \(duration) is not one of the supported exact rates."
    case let .invalidTimecodeFrame(frame):
      return "Timecode frame \(frame) is outside the unsigned 32-bit range."
    case .invalidTimecodeTimestamp:
      return "Timecode sample presentation time must be a numeric, non-negative CMTime."
    case .invalidTimecodeDuration:
      return "Timecode sample duration must be a positive numeric CMTime."
    case let .timecodeFormatCreationFailed(status):
      return "Could not create the ProRes timecode format description (OSStatus \(status))."
    case let .sampleCreationFailed(status):
      return "Could not create the ProRes timecode sample buffer (OSStatus \(status))."
    case let .encoderUnavailable(codec, width, height, reason):
      return "VideoToolbox has no \(codec) encoder for \(width) × \(height): \(reason)."
    case let .encoderCapabilityQueryFailed(codec, status):
      return "VideoToolbox capability query for \(codec) failed (OSStatus \(status))."
    }
  }

  private static func fourCC(_ value: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
    guard bytes.allSatisfy({ (32...126).contains($0) }) else {
      return String(format: "0x%08X", value)
    }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
  }
}

/// Exact source frame rates accepted by the recorder.
public struct ProResFrameRate: Equatable, Sendable {
  public let frameDuration: CMTime
  public let nominalFramesPerSecond: Int
  public let isDropFrameRate: Bool

  public init(frameDuration: CMTime) throws {
    guard frameDuration.isValid, frameDuration.isNumeric, frameDuration.value > 0,
      frameDuration.timescale > 0 else {
      throw ProResRecordingError.unsupportedFrameRate(frameDuration)
    }
    let supported: [(CMTime, Int, Bool)] = [
      (CMTime(value: 1001, timescale: 24_000), 24, false),
      (CMTime(value: 1, timescale: 24), 24, false),
      (CMTime(value: 1, timescale: 25), 25, false),
      (CMTime(value: 1001, timescale: 30_000), 30, true),
      (CMTime(value: 1, timescale: 30), 30, false),
      (CMTime(value: 1, timescale: 50), 50, false),
      (CMTime(value: 1001, timescale: 60_000), 60, true),
      (CMTime(value: 1, timescale: 60), 60, false),
    ]
    guard let match = supported.first(where: { CMTimeCompare($0.0, frameDuration) == 0 }) else {
      throw ProResRecordingError.unsupportedFrameRate(frameDuration)
    }
    self.frameDuration = match.0
    self.nominalFramesPerSecond = match.1
    self.isDropFrameRate = match.2
  }

  public var framesPerSecond: Double { Double(frameDuration.timescale) / Double(frameDuration.value) }
}

/// The source pixel format and timing that the ProRes writer will receive.
public struct ProRes422SourceFormat: Equatable, Sendable {
  public static let maximumDimension = 8_192

  public let width: Int
  public let height: Int
  public let pixelFormat: OSType
  public let frameRate: ProResFrameRate

  public init(width: Int, height: Int, pixelFormat: OSType,
              frameDuration: CMTime) throws {
    guard width > 0, height > 0 else {
      throw ProResRecordingError.invalidDimensions(width: width, height: height)
    }
    guard width <= Self.maximumDimension, height <= Self.maximumDimension else {
      throw ProResRecordingError.dimensionsTooLarge(width: width, height: height,
        maximum: Self.maximumDimension)
    }
    guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
      throw ProResRecordingError.dimensionsMustBeEven(width: width, height: height)
    }
    guard Self.supportedPixelFormats.contains(pixelFormat) else {
      throw ProResRecordingError.unsupportedPixelFormat(pixelFormat)
    }
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    self.frameRate = try ProResFrameRate(frameDuration: frameDuration)
  }

  public static let supportedPixelFormats: Set<OSType> = [
    kCVPixelFormatType_422YpCbCr10,
    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
  ]
}

/// ProRes 422 family members supported by the writer.
public enum ProRes422Profile: String, CaseIterable, Sendable {
  case standard
  case highQuality

  public static let proRes422: Self = .standard
  public static let proRes422HQ: Self = .highQuality

  public var codec: AVVideoCodecType {
    switch self {
    case .standard: return .proRes422
    case .highQuality: return .proRes422HQ
    }
  }

  public var codecType: CMVideoCodecType {
    switch self {
    case .standard: return kCMVideoCodecType_AppleProRes422
    case .highQuality: return kCMVideoCodecType_AppleProRes422HQ
    }
  }

  public var displayName: String {
    switch self {
    case .standard: return "Apple ProRes 422"
    case .highQuality: return "Apple ProRes 422 HQ"
    }
  }
}

/// Controls whether a configuration asks VideoToolbox for a live capability probe.
/// Synthetic tests can use ``assumedAvailable`` while production uses ``system``.
public enum ProResEncoderAvailability: Equatable, Sendable {
  case system
  case assumedAvailable
  case unavailable(String)
}

/// A VideoToolbox encoder selected for a ProRes profile.
public struct ProResEncoderInfo: Equatable, Sendable {
  public let encoderID: String
  public let hardwareAccelerated: Bool
  public let supportedPropertyKeys: Set<String>
}

/// A timecode track that can be attached to the video input with a timecode
/// track association. Samples use the QuickTime 32-bit `tmcd` representation.
public final class ProResTimecodeTrack {
  public let frameRate: ProResFrameRate
  public let dropFrame: Bool
  public let sourceReferenceName: String?
  public let formatDescription: CMTimeCodeFormatDescription

  public init(frameRate: ProResFrameRate, dropFrame: Bool? = nil,
              sourceReferenceName: String? = nil) throws {
    self.frameRate = frameRate
    self.dropFrame = dropFrame ?? frameRate.isDropFrameRate
    self.sourceReferenceName = sourceReferenceName

    var extensions: CFDictionary?
    if let sourceReferenceName {
      extensions = [
        kCMTimeCodeFormatDescriptionExtension_SourceReferenceName as String: [
          kCMTimeCodeFormatDescriptionKey_Value as String: sourceReferenceName,
        ],
      ] as CFDictionary
    }
    var description: CMTimeCodeFormatDescription?
    let status = CMTimeCodeFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
      frameDuration: frameRate.frameDuration,
      frameQuanta: UInt32(frameRate.nominalFramesPerSecond),
      flags: self.dropFrame ? UInt32(kCMTimeCodeFlag_DropFrame) : 0,
      extensions: extensions,
      formatDescriptionOut: &description)
    guard status == noErr, let description else {
      throw ProResRecordingError.timecodeFormatCreationFailed(status)
    }
    self.formatDescription = description
  }

  public func makeInput() -> AVAssetWriterInput {
    let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
      sourceFormatHint: formatDescription)
    return input
  }

  /// Builds one 32-bit timecode sample. `frameNumber` is the frame count from
  /// the start of the timecode day; callers should apply SMPTE drop-frame math
  /// before passing it here.
  public func makeSample(frameNumber: Int64, presentationTime: CMTime,
                         duration: CMTime? = nil) throws -> CMSampleBuffer {
    guard frameNumber >= 0, frameNumber <= Int64(UInt32.max) else {
      throw ProResRecordingError.invalidTimecodeFrame(frameNumber)
    }
    guard presentationTime.isValid, presentationTime.isNumeric,
      presentationTime.value >= 0 else {
      throw ProResRecordingError.invalidTimecodeTimestamp
    }
    let sampleDuration = duration ?? frameRate.frameDuration
    guard sampleDuration.isValid, sampleDuration.isNumeric,
      sampleDuration.value > 0 else {
      throw ProResRecordingError.invalidTimecodeDuration
    }

    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateEmpty(
      allocator: kCFAllocatorDefault, capacity: 1, flags: 0,
      blockBufferOut: &block)
    guard status == kCMBlockBufferNoErr, let block else {
      throw ProResRecordingError.sampleCreationFailed(status)
    }
    status = CMBlockBufferAppendMemoryBlock(
      block, memoryBlock: nil, length: MemoryLayout<UInt32>.size,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
      offsetToData: 0, dataLength: MemoryLayout<UInt32>.size, flags: 0)
    guard status == kCMBlockBufferNoErr else {
      throw ProResRecordingError.sampleCreationFailed(status)
    }

    var bigEndian = UInt32(frameNumber).bigEndian
    status = withUnsafeBytes(of: &bigEndian) { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: bytes.count)
    }
    guard status == kCMBlockBufferNoErr else {
      throw ProResRecordingError.sampleCreationFailed(status)
    }

    var timing = CMSampleTimingInfo(duration: sampleDuration,
      presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var sampleSize = MemoryLayout<UInt32>.size
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: formatDescription, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
      sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw ProResRecordingError.sampleCreationFailed(status)
    }
    return sample
  }
}

/// Fully validated AVAssetWriter settings for a 10-bit 4:2:2 ProRes recording.
public struct ProResRecordingConfiguration {
  public static let bitDepth = 10
  public static let chromaSubsampling = "4:2:2"

  public let source: ProRes422SourceFormat
  public let profile: ProRes422Profile
  public let encoder: ProResEncoderInfo
  public let videoSettings: [String: Any]
  public let sourcePixelBufferAttributes: [String: Any]
  public let timecodeTrack: ProResTimecodeTrack

  public static func inspectEncoder(profile: ProRes422Profile, width: Int,
                                    height: Int,
                                    pixelFormat: OSType = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    throws -> ProResEncoderInfo {
    try ProResEncoderInspector.inspect(profile: profile, width: width, height: height,
      pixelFormat: pixelFormat)
  }

  public init(source: ProRes422SourceFormat, profile: ProRes422Profile = .standard,
              timecode: ProResTimecodeTrack? = nil,
              encoderAvailability: ProResEncoderAvailability = .system) throws {
    self.source = source
    self.profile = profile
    switch encoderAvailability {
    case .system:
      self.encoder = try ProResEncoderInspector.inspect(profile: profile,
        width: source.width, height: source.height, pixelFormat: source.pixelFormat)
    case .assumedAvailable:
      self.encoder = ProResEncoderInfo(encoderID: "assumed",
        hardwareAccelerated: false, supportedPropertyKeys: [])
    case let .unavailable(reason):
      throw ProResRecordingError.encoderUnavailable(codec: profile.displayName,
        width: source.width, height: source.height, reason: reason)
    }

    self.videoSettings = [
      AVVideoCodecKey: profile.codec,
      AVVideoWidthKey: source.width,
      AVVideoHeightKey: source.height,
      AVVideoCompressionPropertiesKey: [
        kVTCompressionPropertyKey_RealTime as String: true,
        kVTCompressionPropertyKey_ExpectedFrameRate as String: source.frameRate.framesPerSecond,
      ],
    ]
    self.sourcePixelBufferAttributes = [
      kCVPixelBufferPixelFormatTypeKey as String: source.pixelFormat,
      kCVPixelBufferWidthKey as String: source.width,
      kCVPixelBufferHeightKey as String: source.height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    self.timecodeTrack = try timecode ?? ProResTimecodeTrack(frameRate: source.frameRate)
  }

  /// Creates the compressed video input. High-bit-depth ProRes inputs must not
  /// specify AVVideoScalingModeKey or AVVideoColorPropertiesKey; the source
  /// pixel-buffer attributes carry the exact dimensions and format instead.
  public func makeVideoInput(sourceFormatHint: CMFormatDescription? = nil) -> AVAssetWriterInput {
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings,
      sourceFormatHint: sourceFormatHint)
    return input
  }

  public func makeTimecodeInput() -> AVAssetWriterInput {
    timecodeTrack.makeInput()
  }

  /// Adds the required QuickTime timecode association from the video input to
  /// the timecode input. Call after both inputs are attached to the same writer.
  public func associateTimecode(videoInput: AVAssetWriterInput,
                                timecodeInput: AVAssetWriterInput) {
    videoInput.addTrackAssociation(withTrackOf: timecodeInput,
      type: AVAssetTrack.AssociationType.timecode.rawValue)
  }
}

private enum ProResEncoderInspector {
  static func inspect(profile: ProRes422Profile, width: Int, height: Int,
                      pixelFormat: OSType = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    throws -> ProResEncoderInfo {
    var list: CFArray?
    let listStatus = VTCopyVideoEncoderList(nil, &list)
    guard listStatus == noErr else {
      throw ProResRecordingError.encoderCapabilityQueryFailed(codec: profile.displayName,
        status: listStatus)
    }

    let entries = (list as? [[String: Any]]) ?? []
    let matching = entries.filter { entry in
      guard let value = entry[kVTVideoEncoderList_CodecType as String] as? NSNumber else { return false }
      return value.uint32Value == profile.codecType
    }
    guard !matching.isEmpty else {
      throw ProResRecordingError.encoderUnavailable(codec: profile.displayName,
        width: width, height: height, reason: "the codec is absent from VTCopyVideoEncoderList")
    }

    let selected = matching.first(where: {
      ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue == true
    }) ?? matching[0]
    let selectedID = selected[kVTVideoEncoderList_EncoderID as String] as? String
    let specification: CFDictionary? = selectedID.map {
      [kVTVideoEncoderSpecification_EncoderID as String: $0] as CFDictionary
    }
    var encoderID: CFString?
    var properties: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(
      width: Int32(width), height: Int32(height), codecType: profile.codecType,
      encoderSpecification: specification, encoderIDOut: &encoderID,
      supportedPropertiesOut: &properties)
    guard status == noErr else {
      throw ProResRecordingError.encoderCapabilityQueryFailed(codec: profile.displayName,
        status: status)
    }
    guard let selectedID,
      sessionSupports(profile: profile, width: width, height: height,
        pixelFormat: pixelFormat, encoderID: selectedID) else {
      throw ProResRecordingError.encoderUnavailable(codec: profile.displayName,
        width: width, height: height,
        reason: "the selected encoder rejected the 10-bit 4:2:2 source pixel format")
    }

    var propertyKeys = Set<String>()
    if let properties {
      for key in (properties as NSDictionary).allKeys {
        propertyKeys.insert(String(describing: key))
      }
    }
    return ProResEncoderInfo(
      encoderID: (encoderID as String?) ?? selectedID,
      hardwareAccelerated: (selected[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false,
      supportedPropertyKeys: propertyKeys)
  }

  private static func sessionSupports(profile: ProRes422Profile, width: Int, height: Int,
                                       pixelFormat: OSType, encoderID: String) -> Bool {
    let specification: CFDictionary = [
      kVTVideoEncoderSpecification_EncoderID as String: encoderID,
    ] as CFDictionary
    let attributes: CFDictionary = [
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ] as CFDictionary
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
      codecType: profile.codecType, encoderSpecification: specification,
      imageBufferAttributes: attributes, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard status == noErr, let session else { return false }
    VTCompressionSessionInvalidate(session)
    return true
  }
}

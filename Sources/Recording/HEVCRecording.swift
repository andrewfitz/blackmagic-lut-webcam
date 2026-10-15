import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The only profile currently offered by the recorder. Keeping the profile
/// contract explicit prevents an encoder from silently changing 10-bit 4:2:2
/// input into 8-bit or 4:2:0 output.
enum HEVCRecordingProfile: String, CaseIterable, Equatable, Sendable {
  case main10_422

  var videoCodec: AVVideoCodecType { AVVideoCodecType.hevc }
  var profileLevel: String { kVTProfileLevel_HEVC_Main42210_AutoLevel as String }
  var pixelFormat: OSType { kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange }
  var bitDepth: Int { 10 }
  var chromaDescription: String { "4:2:2" }
}

enum HEVCEncoderPreference: Equatable, Sendable {
  /// Prefer a hardware encoder, but permit an exact-profile software encoder.
  case hardwarePreferred
  /// Reject a software fallback. This is useful when real-time throughput is
  /// part of the recording contract.
  case hardwareRequired
  /// Use software only, primarily for diagnostics and qualification.
  case softwareOnly
}

struct HEVCRecordingConfiguration: Equatable, Sendable {
  var width: Int
  var height: Int
  var frameRate: Double
  var averageBitRate: Int?
  var encoderPreference: HEVCEncoderPreference
  var profile: HEVCRecordingProfile

  init(width: Int, height: Int, frameRate: Double,
    averageBitRate: Int? = nil,
    encoderPreference: HEVCEncoderPreference = .hardwarePreferred,
    profile: HEVCRecordingProfile = .main10_422) {
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.averageBitRate = averageBitRate
    self.encoderPreference = encoderPreference
    self.profile = profile
  }
}

enum HEVCRecordingError: LocalizedError, Equatable {
  case invalidDimensions
  case invalidFrameRate
  case unsupportedProfile(HEVCRecordingProfile)
  case hardwareEncoderUnavailable(HEVCRecordingProfile)
  case softwareEncoderUnavailable(HEVCRecordingProfile)
  case noVideoEncoder
  case capabilityProbeFailed(OSStatus)
  case writerConfigurationFailed(String)
  case writerStartFailed(String)
  case writerAppendFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidDimensions: return "HEVC Main 10 4:2:2 recording dimensions must be positive, even, and fit Core Media limits."
    case .invalidFrameRate: return "HEVC recording frame rate must be finite and positive."
    case .unsupportedProfile(let profile):
      return "No VideoToolbox encoder supports the requested \(profile.rawValue) profile."
    case .hardwareEncoderUnavailable(let profile):
      return "No hardware VideoToolbox encoder supports the requested \(profile.rawValue) profile."
    case .softwareEncoderUnavailable(let profile):
      return "No software VideoToolbox encoder supports the requested \(profile.rawValue) profile."
    case .noVideoEncoder: return "VideoToolbox did not report an HEVC encoder."
    case .capabilityProbeFailed(let status): return "VideoToolbox capability probing failed (\(status))."
    case .writerConfigurationFailed(let reason): return "Could not configure the HEVC writer: \(reason)"
    case .writerStartFailed(let reason): return "Could not start the HEVC writer: \(reason)"
    case .writerAppendFailed(let reason): return "Could not append a frame to the HEVC writer: \(reason)"
    }
  }
}

/// A candidate discovered from VideoToolbox's encoder list. The profile bit is
/// established by probing the encoder's supported property dictionary and by
/// creating a compression session with the exact input pixel format.
struct HEVCEncoderCandidate: Equatable, Sendable {
  let encoderID: String
  let isHardwareAccelerated: Bool
  let supportsMain10_422: Bool

  init(encoderID: String, isHardwareAccelerated: Bool, supportsMain10_422: Bool) {
    self.encoderID = encoderID
    self.isHardwareAccelerated = isHardwareAccelerated
    self.supportsMain10_422 = supportsMain10_422
  }
}

struct HEVCEncoderSelection: Equatable, Sendable {
  let encoderID: String
  let isHardwareAccelerated: Bool
  let profile: HEVCRecordingProfile
  let fallbackReason: String?

  var encoderLabel: String { isHardwareAccelerated ? "hardware" : "software" }
}

/// Resolves an already-probed encoder list. It is separate from the system
/// probe so fallback policy can be tested without depending on host hardware.
struct HEVCEncoderSelectionResolver {
  static func resolve(_ candidates: [HEVCEncoderCandidate], profile: HEVCRecordingProfile,
    preference: HEVCEncoderPreference) throws -> HEVCEncoderSelection {
    let exact = candidates.filter { $0.supportsMain10_422 }
    guard !exact.isEmpty else { throw HEVCRecordingError.unsupportedProfile(profile) }

    switch preference {
    case .hardwareRequired:
      guard let hardware = exact.first(where: { $0.isHardwareAccelerated }) else {
        throw HEVCRecordingError.hardwareEncoderUnavailable(profile)
      }
      return HEVCEncoderSelection(encoderID: hardware.encoderID, isHardwareAccelerated: true,
        profile: profile, fallbackReason: nil)
    case .softwareOnly:
      guard let software = exact.first(where: { !$0.isHardwareAccelerated }) else {
        throw HEVCRecordingError.softwareEncoderUnavailable(profile)
      }
      return HEVCEncoderSelection(encoderID: software.encoderID, isHardwareAccelerated: false,
        profile: profile, fallbackReason: nil)
    case .hardwarePreferred:
      if let hardware = exact.first(where: { $0.isHardwareAccelerated }) {
        return HEVCEncoderSelection(encoderID: hardware.encoderID, isHardwareAccelerated: true,
          profile: profile, fallbackReason: nil)
      }
      let software = exact[0]
      return HEVCEncoderSelection(encoderID: software.encoderID, isHardwareAccelerated: false,
        profile: profile, fallbackReason: "Hardware encoder unavailable; using software encoder.")
    }
  }
}

protocol HEVCEncoderCatalog {
  func candidates(width: Int, height: Int, profile: HEVCRecordingProfile) throws -> [HEVCEncoderCandidate]
}

/// VideoToolbox-backed capability probe. It checks the encoder list first,
/// then creates a short-lived compression session for each exact candidate.
/// This catches hosts where the profile is advertised but the requested
/// 10-bit 4:2:2 input format is rejected at session creation time.
struct VideoToolboxHEVCEncoderCatalog: HEVCEncoderCatalog {
  func candidates(width: Int, height: Int, profile: HEVCRecordingProfile) throws -> [HEVCEncoderCandidate] {
    guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
      width.isMultiple(of: 2), height.isMultiple(of: 2) else {
      throw HEVCRecordingError.invalidDimensions
    }
    var encoderList: CFArray?
    let listStatus = VTCopyVideoEncoderList(nil, &encoderList)
    guard listStatus == noErr else { throw HEVCRecordingError.capabilityProbeFailed(listStatus) }
    guard let entries = encoderList as? [[String: Any]], !entries.isEmpty else {
      throw HEVCRecordingError.noVideoEncoder
    }

    var result: [HEVCEncoderCandidate] = []
    for entry in entries {
      guard let codec = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value,
        codec == kCMVideoCodecType_HEVC,
        let encoderID = entry[kVTVideoEncoderList_EncoderID as String] as? String else { continue }
      let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
      guard advertisedProfile(entry, profile: profile) || encoderSupportsProfile(
        profile: profile, width: width, height: height, encoderID: encoderID) else { continue }
      guard sessionSupports(profile: profile, width: width, height: height,
        encoderID: encoderID) else { continue }
      result.append(HEVCEncoderCandidate(encoderID: encoderID, isHardwareAccelerated: hardware,
        supportsMain10_422: true))
    }
    return result
  }

  private func advertisedProfile(_ entry: [String: Any], profile: HEVCRecordingProfile) -> Bool {
    let expected = profile.profileLevel
    func contains(_ value: Any) -> Bool {
      if let string = value as? String { return string == expected }
      if let values = value as? [Any] { return values.contains(where: contains) }
      if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: contains) }
      return false
    }
    return contains(entry[kVTVideoEncoderList_SupportedSelectionProperties as String] as Any)
  }

  private func encoderSupportsProfile(profile: HEVCRecordingProfile, width: Int, height: Int,
    encoderID: String) -> Bool {
    let specification: CFDictionary = [kVTVideoEncoderSpecification_EncoderID as String: encoderID] as CFDictionary
    var returnedID: CFString?
    var properties: CFDictionary?
    let status = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification,
      encoderIDOut: &returnedID, supportedPropertiesOut: &properties)
    guard status == noErr, let properties else { return false }
    let expected = profile.profileLevel
    func contains(_ value: Any) -> Bool {
      if let string = value as? String { return string == expected }
      if let values = value as? [Any] { return values.contains(where: contains) }
      if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: contains) }
      return false
    }
    return contains(properties as Any)
  }

  private func sessionSupports(profile: HEVCRecordingProfile, width: Int, height: Int,
    encoderID: String) -> Bool {
    let specification: CFDictionary = [kVTVideoEncoderSpecification_EncoderID as String: encoderID] as CFDictionary
    let attributes: CFDictionary = [
      kCVPixelBufferPixelFormatTypeKey as String: profile.pixelFormat,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ] as CFDictionary
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification,
      imageBufferAttributes: attributes, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard status == noErr, let session else { return false }
    defer { VTCompressionSessionInvalidate(session) }
    guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
      value: profile.profileLevel as CFString) == noErr else { return false }
    return true
  }
}

struct HEVCRecordingCapabilityProbe {
  var catalog: any HEVCEncoderCatalog

  init(catalog: any HEVCEncoderCatalog = VideoToolboxHEVCEncoderCatalog()) {
    self.catalog = catalog
  }

  func selectEncoder(for configuration: HEVCRecordingConfiguration) throws -> HEVCEncoderSelection {
    guard configuration.width > 0, configuration.height > 0,
      configuration.width <= Int(Int32.max), configuration.height <= Int(Int32.max),
      configuration.width.isMultiple(of: 2), configuration.height.isMultiple(of: 2) else {
      throw HEVCRecordingError.invalidDimensions
    }
    guard configuration.frameRate.isFinite, configuration.frameRate > 0 else {
      throw HEVCRecordingError.invalidFrameRate
    }
    let candidates = try catalog.candidates(width: configuration.width, height: configuration.height,
      profile: configuration.profile)
    return try HEVCEncoderSelectionResolver.resolve(candidates, profile: configuration.profile,
      preference: configuration.encoderPreference)
  }
}

/// AVAssetWriter configuration for the exact selected VideoToolbox encoder.
/// The encoder specification is top-level, as required by AVFoundation; the
/// profile remains explicit so AVAssetWriter cannot silently pick Main 8-bit.
struct HEVCAssetWriterContract {
  static func outputSettings(configuration: HEVCRecordingConfiguration,
    selection: HEVCEncoderSelection) -> [String: Any] {
    var encoderSpecification: [String: Any] = [
      kVTVideoEncoderSpecification_EncoderID as String: selection.encoderID,
    ]
    if selection.isHardwareAccelerated {
      // A selected hardware encoder must not silently become software between
      // the capability probe and AVAssetWriter session creation.
      encoderSpecification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
    }
    var settings: [String: Any] = [
      AVVideoCodecKey: configuration.profile.videoCodec,
      AVVideoWidthKey: configuration.width,
      AVVideoHeightKey: configuration.height,
      AVVideoProfileLevelKey: configuration.profile.profileLevel,
      AVVideoExpectedSourceFrameRateKey: Int(configuration.frameRate.rounded()),
      AVVideoAllowFrameReorderingKey: false,
      AVVideoEncoderSpecificationKey: encoderSpecification,
      AVVideoCompressionPropertiesKey: [
        kVTCompressionPropertyKey_ProfileLevel as String: configuration.profile.profileLevel,
        kVTCompressionPropertyKey_AllowFrameReordering as String: false,
      ],
    ]
    if let bitRate = configuration.averageBitRate, bitRate > 0 {
      settings[AVVideoCompressionPropertiesKey] = [
        kVTCompressionPropertyKey_ProfileLevel as String: configuration.profile.profileLevel,
        kVTCompressionPropertyKey_AllowFrameReordering as String: false,
        kVTCompressionPropertyKey_AverageBitRate as String: bitRate,
      ]
    }
    return settings
  }

  static func pixelBufferAttributes(for profile: HEVCRecordingProfile) -> [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: profile.pixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
  }
}

/// Thin AVAssetWriter owner. It deliberately accepts only the selected profile
/// pixel format and performs capability probing before creating the writer.
final class HEVCAssetWriter: @unchecked Sendable {
  let writer: AVAssetWriter
  let input: AVAssetWriterInput
  let adaptor: AVAssetWriterInputPixelBufferAdaptor
  let selection: HEVCEncoderSelection
  let configuration: HEVCRecordingConfiguration

  init(url: URL, configuration: HEVCRecordingConfiguration,
    probe: HEVCRecordingCapabilityProbe = HEVCRecordingCapabilityProbe()) throws {
    let selected = try probe.selectEncoder(for: configuration)
    let outputSettings = HEVCAssetWriterContract.outputSettings(configuration: configuration, selection: selected)
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    } catch {
      throw HEVCRecordingError.writerConfigurationFailed(error.localizedDescription)
    }
    input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: HEVCAssetWriterContract.pixelBufferAttributes(for: configuration.profile))
    guard writer.canAdd(input) else {
      throw HEVCRecordingError.writerConfigurationFailed("AVAssetWriter rejected the video input.")
    }
    writer.add(input)
    selection = selected
    self.configuration = configuration
  }

  func start(at sourceTime: CMTime) throws {
    guard writer.startWriting() else {
      throw HEVCRecordingError.writerStartFailed(writer.error?.localizedDescription ?? "unknown error")
    }
    writer.startSession(atSourceTime: sourceTime)
  }

  @discardableResult
  func append(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) throws -> Bool {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == configuration.profile.pixelFormat else {
      throw HEVCRecordingError.writerAppendFailed("Expected 10-bit 4:2:2 video-range input.")
    }
    guard input.isReadyForMoreMediaData else { return false }
    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
      throw HEVCRecordingError.writerAppendFailed(writer.error?.localizedDescription ?? "unknown error")
    }
    return true
  }

  func cancel() {
    input.markAsFinished()
    writer.cancelWriting()
  }
}

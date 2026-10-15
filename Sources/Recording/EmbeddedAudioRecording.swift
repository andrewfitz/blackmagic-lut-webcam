import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Errors raised while validating an embedded Blackmagic audio packet.
public enum EmbeddedAudioError: Error, Equatable {
  case invalidChannelCount
  case invalidSampleFrameCount
  case byteCountMismatch(expected: Int, actual: Int)
  case invalidPresentationTime
  case formatDescriptionCreationFailed(OSStatus)
  case blockBufferCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)
}

/// The audio contract used by Blackmagic embedded audio capture.
///
/// Blackmagic's 32-bit integer input is interleaved, signed, little-endian
/// PCM. The recorder stores the 24 significant high bits in packed little
/// endian samples. This preserves the source's 24-bit signal while avoiding a
/// lossy float conversion.
public enum EmbeddedAudioFormat {
  public static let sampleRate: Double = 48_000
  public static let sampleRateTimescale: Int32 = 48_000
  public static let channelCount = 2
  public static let sourceBitDepth = 32
  public static let recordingBitDepth = 24
  public static let sourceBytesPerSample = sourceBitDepth / 8
  public static let recordingBytesPerSample = recordingBitDepth / 8
  public static let recordingBytesPerFrame = channelCount * recordingBytesPerSample

  /// Settings for an AVAssetWriter audio input. The PCM input is interleaved,
  /// signed, native-endian and packed at 24 bits per channel.
  public static var assetWriterSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: recordingBitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }
}

/// Converts Blackmagic's interleaved signed 32-bit PCM to packed signed
/// little-endian 24-bit PCM without going through floating point.
public enum BlackmagicAudioConverter {
  /// Converts bytes containing interleaved little-endian Int32 samples.
  ///
  /// The low eight bits are discarded with an arithmetic shift. This is the
  /// exact representation conversion for a source whose 24 signal bits are
  /// left aligned in a 32-bit sample. The result has three bytes per sample,
  /// in little-endian order, and remains interleaved by channel.
  public static func convert32BitIntegerPCMTo24BitPacked(
    _ source: Data,
    channelCount: Int = EmbeddedAudioFormat.channelCount
  ) throws -> Data {
    guard channelCount > 0,
          channelCount <= Int.max / EmbeddedAudioFormat.sourceBytesPerSample else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    let bytesPerFrame = channelCount * EmbeddedAudioFormat.sourceBytesPerSample
    guard source.count % bytesPerFrame == 0 else {
      throw EmbeddedAudioError.byteCountMismatch(
        expected: source.count / bytesPerFrame * bytesPerFrame + bytesPerFrame,
        actual: source.count
      )
    }

    let sampleCount = source.count / EmbeddedAudioFormat.sourceBytesPerSample
    var result = Data(count: sampleCount * EmbeddedAudioFormat.recordingBytesPerSample)
    source.withUnsafeBytes { sourceBytes in
      result.withUnsafeMutableBytes { outputBytes in
        guard let sourceBase = sourceBytes.baseAddress,
              let outputBase = outputBytes.baseAddress else { return }
        for sampleIndex in 0..<sampleCount {
          let sourceOffset = sampleIndex * EmbeddedAudioFormat.sourceBytesPerSample
          let raw = sourceBase.loadUnaligned(fromByteOffset: sourceOffset, as: UInt32.self)
          let littleEndian = UInt32(littleEndian: raw)
          let sample = Int32(bitPattern: littleEndian)
          let significant = Int32(truncatingIfNeeded: sample >> 8)
          let packed = UInt32(bitPattern: significant)
          let outputOffset = sampleIndex * EmbeddedAudioFormat.recordingBytesPerSample
          outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed),
            toByteOffset: outputOffset, as: UInt8.self)
          outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 8),
            toByteOffset: outputOffset + 1, as: UInt8.self)
          outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 16),
            toByteOffset: outputOffset + 2, as: UInt8.self)
        }
      }
    }
    return result
  }

  /// Converts an array of host-endian Int32 samples. The host is expected to
  /// be little-endian on supported macOS targets; this overload is intended
  /// for tests and code that already decoded the DeckLink packet.
  public static func convert32BitIntegerSamplesTo24BitPacked(
    _ source: [Int32]
  ) -> Data {
    var result = Data(count: source.count * EmbeddedAudioFormat.recordingBytesPerSample)
    result.withUnsafeMutableBytes { outputBytes in
      guard let outputBase = outputBytes.baseAddress else { return }
      for (sampleIndex, sample) in source.enumerated() {
        let significant = Int32(truncatingIfNeeded: sample >> 8)
        let packed = UInt32(bitPattern: significant)
        let outputOffset = sampleIndex * EmbeddedAudioFormat.recordingBytesPerSample
        outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed),
          toByteOffset: outputOffset, as: UInt8.self)
        outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 8),
          toByteOffset: outputOffset + 1, as: UInt8.self)
        outputBase.storeBytes(of: UInt8(truncatingIfNeeded: packed >> 16),
          toByteOffset: outputOffset + 2, as: UInt8.self)
      }
    }
    return result
  }
}

/// A packet ready for an AVAssetWriter input.
public struct EmbeddedAudioPacket {
  public let pcm24: Data
  public let sampleFrameCount: Int
  public let presentationTime: CMTime

  public init(
    sourcePCM32: Data,
    sampleFrameCount: Int,
    presentationTime: CMTime,
    channelCount: Int = EmbeddedAudioFormat.channelCount
  ) throws {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    guard channelCount == EmbeddedAudioFormat.channelCount else {
      throw EmbeddedAudioError.invalidChannelCount
    }
    guard presentationTime.isNumeric else { throw EmbeddedAudioError.invalidPresentationTime }
    let expectedBytes = sampleFrameCount * channelCount * EmbeddedAudioFormat.sourceBytesPerSample
    guard sourcePCM32.count == expectedBytes else {
      throw EmbeddedAudioError.byteCountMismatch(expected: expectedBytes, actual: sourcePCM32.count)
    }
    self.pcm24 = try BlackmagicAudioConverter.convert32BitIntegerPCMTo24BitPacked(
      sourcePCM32, channelCount: channelCount)
    self.sampleFrameCount = sampleFrameCount
    self.presentationTime = presentationTime
  }

  public var duration: CMTime {
    CMTime(value: Int64(sampleFrameCount), timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }
}

/// Generates exact sample-frame presentation times. Keeping the running
/// position as an integer at 48 kHz prevents the cumulative rounding drift
/// that results from repeatedly adding Double durations.
public struct EmbeddedAudioTimeline {
  public private(set) var emittedSampleFrames: Int64 = 0

  public init() {}

  public mutating func reset() {
    emittedSampleFrames = 0
  }

  public mutating func nextPacketTiming(sampleFrameCount: Int) throws -> (presentationTime: CMTime, duration: CMTime) {
    guard sampleFrameCount > 0 else { throw EmbeddedAudioError.invalidSampleFrameCount }
    let presentationTime = CMTime(value: emittedSampleFrames,
      timescale: EmbeddedAudioFormat.sampleRateTimescale)
    let duration = CMTime(value: Int64(sampleFrameCount),
      timescale: EmbeddedAudioFormat.sampleRateTimescale)
    emittedSampleFrames += Int64(sampleFrameCount)
    return (presentationTime, duration)
  }

  public static func time(forSampleFrameOffset offset: Int64) -> CMTime {
    CMTime(value: offset, timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }
}

/// AVFoundation glue for direct embedded audio recording.
public enum EmbeddedAudioRecording {
  public static func makeWriterInput() -> AVAssetWriterInput {
    AVAssetWriterInput(mediaType: .audio, outputSettings: EmbeddedAudioFormat.assetWriterSettings)
  }

  /// Builds a ready CMSampleBuffer from a converted packet. The sample buffer
  /// retains the packet's exact PTS and uses one 48 kHz duration per frame.
  public static func makeSampleBuffer(for packet: EmbeddedAudioPacket) throws -> CMSampleBuffer {
    var streamDescription = AudioStreamBasicDescription(
      mSampleRate: EmbeddedAudioFormat.sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(EmbeddedAudioFormat.recordingBytesPerFrame),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(EmbeddedAudioFormat.recordingBytesPerFrame),
      mChannelsPerFrame: UInt32(EmbeddedAudioFormat.channelCount),
      mBitsPerChannel: UInt32(EmbeddedAudioFormat.recordingBitDepth),
      mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
      throw EmbeddedAudioError.formatDescriptionCreationFailed(status)
    }

    var blockBuffer: CMBlockBuffer?
    // Allocate storage owned by CoreMedia, then copy the converted packet.
    // Passing Data's pointer directly would leave a sample buffer referring to
    // storage that can be released as soon as this method returns.
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: packet.pcm24.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: packet.pcm24.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
      throw EmbeddedAudioError.blockBufferCreationFailed(status)
    }
    status = packet.pcm24.withUnsafeBytes { bytes in
      guard let source = bytes.baseAddress else { return kCMBlockBufferNoErr }
      return CMBlockBufferReplaceDataBytes(
        with: source,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: packet.pcm24.count
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw EmbeddedAudioError.blockBufferCreationFailed(status)
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: EmbeddedAudioFormat.sampleRateTimescale),
      presentationTimeStamp: packet.presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleSize = packet.pcm24.count / packet.sampleFrameCount
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: packet.sampleFrameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
      throw EmbeddedAudioError.sampleBufferCreationFailed(status)
    }
    return sampleBuffer
  }
}

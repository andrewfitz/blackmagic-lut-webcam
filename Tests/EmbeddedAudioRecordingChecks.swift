import AVFoundation
import CoreMedia
import Foundation
import XCTest

@objcMembers final class EmbeddedAudioRecordingChecks: XCTestCase {
  func testExactSigned32ToPacked24Conversion() throws {
    let values: [Int32] = [
      0,
      0x12345678,
      0x7FFFFF00,
      Int32(bitPattern: 0x80000000),
      -1,
      -0x12345678,
    ]
    var source = Data()
    for value in values {
      var littleEndian = UInt32(bitPattern: value).littleEndian
      withUnsafeBytes(of: &littleEndian) { source.append(contentsOf: $0) }
    }

    let packed = try BlackmagicAudioConverter.convert32BitIntegerPCMTo24BitPacked(source, channelCount: 2)
    XCTAssertEqual(Array(packed), [
      0x00, 0x00, 0x00,
      0x56, 0x34, 0x12,
      0xFF, 0xFF, 0x7F,
      0x00, 0x00, 0x80,
      0xFF, 0xFF, 0xFF,
      0xA9, 0xCB, 0xED,
    ])
  }

  func testConversionRejectsPartialInterleavedFrame() {
    XCTAssertThrowsError(try BlackmagicAudioConverter.convert32BitIntegerPCMTo24BitPacked(
      Data(repeating: 0, count: 9), channelCount: 2)) { error in
      XCTAssertEqual(error as? EmbeddedAudioError,
        .byteCountMismatch(expected: 16, actual: 9))
    }
  }

  func testTimelineKeepsInteger48KHzClockWithoutDrift() throws {
    var timeline = EmbeddedAudioTimeline()
    var frameOffset: Int64 = 0
    var lastEnd = CMTime.zero
    for packetIndex in 0..<12_000 {
      // Deliberately vary packet sizes like a capture callback does. Every
      // packet still advances by an exact integer number of audio frames.
      let frameCount = [799, 800, 801][packetIndex % 3]
      let timing = try timeline.nextPacketTiming(sampleFrameCount: frameCount)
      XCTAssertEqual(timing.presentationTime,
        CMTime(value: frameOffset, timescale: EmbeddedAudioFormat.sampleRateTimescale))
      XCTAssertEqual(timing.duration,
        CMTime(value: Int64(frameCount), timescale: EmbeddedAudioFormat.sampleRateTimescale))
      XCTAssertEqual(timing.presentationTime, lastEnd)
      frameOffset += Int64(frameCount)
      lastEnd = CMTime(value: frameOffset, timescale: EmbeddedAudioFormat.sampleRateTimescale)
    }
    XCTAssertEqual(timeline.emittedSampleFrames, frameOffset)
    XCTAssertEqual(EmbeddedAudioTimeline.time(forSampleFrameOffset: frameOffset), lastEnd)
  }

  func testWriterSettingsDescribe48KHzInterleaved24BitPCM() {
    let settings = EmbeddedAudioFormat.assetWriterSettings
    XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
    XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 24)
    XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
    XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
  }

  func testPacketAndSampleBufferRetainExactPTS() throws {
    let sampleFrames = 800
    let source = Data(repeating: 0, count: sampleFrames * EmbeddedAudioFormat.channelCount * 4)
    let pts = CMTime(value: 1_234_567, timescale: EmbeddedAudioFormat.sampleRateTimescale)
    let packet = try EmbeddedAudioPacket(sourcePCM32: source, sampleFrameCount: sampleFrames,
      presentationTime: pts)
    XCTAssertEqual(packet.pcm24.count, sampleFrames * EmbeddedAudioFormat.recordingBytesPerFrame)
    XCTAssertEqual(packet.duration, CMTime(value: 800, timescale: 48_000))

    let sampleBuffer = try EmbeddedAudioRecording.makeSampleBuffer(for: packet)
    XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), sampleFrames)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), pts)
    XCTAssertEqual(CMSampleBufferGetDuration(sampleBuffer), packet.duration)
  }

  static let allTests = [
    ("exact signed 32 to packed 24 conversion", testExactSigned32ToPacked24Conversion),
    ("reject partial interleaved frame", testConversionRejectsPartialInterleavedFrame),
    ("integer 48 kHz timeline", testTimelineKeepsInteger48KHzClockWithoutDrift),
    ("writer settings", testWriterSettingsDescribe48KHzInterleaved24BitPCM),
    ("packet sample buffer PTS", testPacketAndSampleBufferRetainExactPTS),
  ]
}

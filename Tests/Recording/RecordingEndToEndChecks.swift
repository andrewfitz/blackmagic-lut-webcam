import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
import VideoToolbox

/// A writer that retains only synthetic sample timing. It makes the recording
/// boundary observable without invoking AVAssetWriter or a hardware encoder.
private final class SyntheticSourceWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var started = false
  private(set) var finished = false
  private(set) var videoSamples: [CMSampleBuffer] = []
  private(set) var audioSamples: [CMSampleBuffer] = []

  func start() throws {
    lock.withLock {
      precondition(!started)
      started = true
    }
  }

  func appendVideo(_ sample: CMSampleBuffer) throws {
    lock.withLock { videoSamples.append(sample) }
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {
    lock.withLock { audioSamples.append(sample) }
  }

  func finish() throws {
    lock.withLock {
      precondition(started)
      finished = true
    }
  }
}

@objcMembers final class RecordingEndToEndChecks: XCTestCase {
  private func videoSample(at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    XCTAssertEqual(status, kCVReturnSuccess)
    return try VideoContract.sample(try XCTUnwrap(pixelBuffer), at: time, duration: duration)
  }

  private func audioSample(at time: CMTime, frameCount: Int = 800) throws -> CMSampleBuffer {
    let source = Data(repeating: 0, count: frameCount * EmbeddedAudioFormat.channelCount * 4)
    let packet = try EmbeddedAudioPacket(sourcePCM32: source, sampleFrameCount: frameCount,
      presentationTime: time)
    return try EmbeddedAudioRecording.makeSampleBuffer(for: packet)
  }

  private func configuration(feed: String, url: URL, queueCapacity: Int = 12,
                             realTimeEncoding: Bool = true,
                             maxKeyFrameInterval: Int = 60) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed), outputURL: url,
      width: 16, height: 16, videoCodec: kCMVideoCodecType_HEVC, fileType: .mov,
      queueCapacity: queueCapacity, realTimeEncoding: realTimeEncoding,
      maxKeyFrameInterval: maxKeyFrameInterval)
  }

  func testTwoFeedsRecordSimultaneouslyAndFinalizeAfterPauseResume() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultracam-recording-e2e-\(UUID().uuidString)")
    let writerA = SyntheticSourceWriter()
    let writerB = SyntheticSourceWriter()
    let duration = RecordingFrameRate.fps2997.frameDuration
    let recorderA = try SourceRecorderCore(configuration: configuration(
      feed: "camera-a", url: root.appendingPathComponent("a.mov")), writerFactory: { writerA })
    let recorderB = try SourceRecorderCore(configuration: configuration(
      feed: "camera-b", url: root.appendingPathComponent("b.mov")), writerFactory: { writerB })

    try recorderA.start()
    try recorderB.start()
    for index in 0..<4 {
      let pts = CMTimeMultiply(duration, multiplier: Int32(index))
      XCTAssertTrue(recorderA.appendVideo(try videoSample(at: pts, duration: duration)))
      XCTAssertTrue(recorderB.appendVideo(try videoSample(at: pts, duration: duration)))
    }
    try recorderA.pause()
    XCTAssertFalse(recorderA.appendVideo(try videoSample(at: CMTime(value: 10_010,
      timescale: 30_000), duration: duration)))
    XCTAssertTrue(recorderB.appendVideo(try videoSample(at: CMTime(value: 4_004,
      timescale: 30_000), duration: duration)))
    try recorderA.resume()
    XCTAssertTrue(recorderA.appendVideo(try videoSample(at: CMTime(value: 10_010,
      timescale: 30_000), duration: duration)))

    try recorderA.stop()
    try recorderB.stop()
    XCTAssertTrue(writerA.finished)
    XCTAssertTrue(writerB.finished)
    XCTAssertEqual(recorderA.state, .finished)
    XCTAssertEqual(recorderB.state, .finished)
    XCTAssertEqual(recorderA.telemetry.appendedVideo, 5)
    XCTAssertEqual(recorderB.telemetry.appendedVideo, 5)
    XCTAssertEqual(recorderA.telemetry.droppedPaused, 1)
    XCTAssertEqual(writerA.videoSamples.count, 5)
    XCTAssertEqual(writerB.videoSamples.count, 5)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(writerA.videoSamples.last!),
      CMTime(value: 10_010, timescale: 30_000))
  }

  func testAudioAndVideoPTSStayAlignedAtBothCaptureRates() throws {
    for rate in [RecordingFrameRate.fps2997, .fps5994] {
      var videoNormalizer = RecordingTimestampNormalizer()
      var audioNormalizer = RecordingTimestampNormalizer()
      var tracker = RecordingAVDriftTracker(maximumDrift: CMTime(value: 1, timescale: 1))
      var audioTime = CMTime.zero
      let audioFrameCount: Int64 = rate == .fps2997 ? 1_601 : 800
      for frame in 0..<600 {
        let videoDuration = rate.frameDuration
        let videoTime = CMTimeMultiply(videoDuration, multiplier: Int32(frame))
        let audioDuration = CMTime(value: audioFrameCount, timescale: 48_000)
        let video = RecordingPacket(mediaKind: .video, presentationTime: videoTime,
          duration: videoDuration)
        let audio = RecordingPacket(mediaKind: .audio, presentationTime: audioTime,
          duration: audioDuration)
        let normalizedVideo = try XCTUnwrap(videoNormalizer.normalize(video).successValue)
        let normalizedAudio = try XCTUnwrap(audioNormalizer.normalize(audio).successValue)
        _ = try tracker.observe(normalizedVideo)
        _ = try tracker.observe(normalizedAudio)
        audioTime = CMTimeAdd(audioTime, audioDuration)
      }
      XCTAssertNotNil(tracker.currentDrift)
      XCTAssertLessThan(abs(CMTimeGetSeconds(tracker.currentDrift!)), 0.02,
        "\(rate) synthetic 48 kHz audio must remain aligned with video")

      let lateAudio = RecordingPacket(mediaKind: .audio,
        presentationTime: CMTimeAdd(tracker.latestAudioEnd!, CMTime(value: 2, timescale: 1)),
        duration: CMTime(value: 1, timescale: 48_000))
      var lateNormalizer = RecordingTimestampNormalizer()
      let late = try XCTUnwrap(lateNormalizer.normalize(lateAudio).successValue)
      XCTAssertThrowsError(try tracker.observe(late)) { error in
        guard case .exceedsLimit = error as? RecordingDriftError else {
          return XCTFail("Expected a bounded drift failure, got \(error)")
        }
      }
    }
  }

  func testDropFrameTimecodeAndSourceAlignmentAtBothRates() throws {
    let expected: [(RecordingFrameRate, Int64, String)] = [
      (.fps2997, 1_800, "00:01:00;02"),
      (.fps5994, 3_600, "00:01:00;04"),
    ]
    for (rate, frame, label) in expected {
      let timecode = RecordingTimecode(frameNumber: frame, frameRate: rate, dropFrame: true)
      XCTAssertEqual(timecode.stringValue, label)
      XCTAssertEqual(RecordingTimecode(string: label, frameRate: rate, dropFrame: true), timecode)
      XCTAssertNil(RecordingTimecode(string: label.replacingOccurrences(of: ";02", with: ";00")
        .replacingOccurrences(of: ";04", with: ";00"), frameRate: rate, dropFrame: true))

      let session = RecordingTimecodeSession(frameRate: rate, dropFrame: true,
        policy: .wallClock, startDate: Date(timeIntervalSince1970: 0), sourceStartTime: .zero,
        calendar: Calendar(identifier: .gregorian))
      let mapped = try XCTUnwrap(session.timecode(for: CMTimeMultiply(rate.frameDuration,
        multiplier: Int32(frame))))
      XCTAssertEqual(mapped.frameNumber, session.startTimecode.frameNumber + frame,
        "Source PTS must advance timecode by exact media frames")
    }

    let sourceSession = RecordingTimecodeSession(frameRate: .fps2997, policy: .source,
      startDate: Date(timeIntervalSince1970: 0))
    let sourceTimecode = RecordingTimecode(frameNumber: 123, frameRate: .fps2997, dropFrame: true)
    XCTAssertEqual(sourceSession.timecode(for: .zero, sourceTimecode: sourceTimecode), sourceTimecode)
    XCTAssertNil(sourceSession.timecode(for: .zero, sourceTimecode: nil))
  }

  func testEncoderSettingsPreserveTenBit422AndSelectionPolicy() throws {
    let configuration = HEVCRecordingConfiguration(width: 3_840, height: 2_160,
      frameRate: 60_000.0 / 1_001.0, averageBitRate: 120_000_000,
      encoderPreference: .hardwarePreferred)
    let candidates = [
      HEVCEncoderCandidate(encoderID: "synthetic.software", isHardwareAccelerated: false,
        supportsMain10_422: true),
    ]
    let selection = try HEVCEncoderSelectionResolver.resolve(candidates,
      profile: configuration.profile, preference: configuration.encoderPreference)
    let settings = HEVCAssetWriterContract.outputSettings(configuration: configuration,
      selection: selection)
    XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, AVVideoCodecType.hevc)
    XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 3_840)
    XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 2_160)
    XCTAssertEqual(settings[AVVideoProfileLevelKey] as? String,
      kVTProfileLevel_HEVC_Main42210_AutoLevel as String)
    XCTAssertEqual((settings[AVVideoExpectedSourceFrameRateKey] as? NSNumber)?.intValue, 60)
    XCTAssertEqual(configuration.profile.pixelFormat,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertFalse(selection.isHardwareAccelerated)
    XCTAssertNotNil(selection.fallbackReason)

    XCTAssertThrowsError(try HEVCEncoderSelectionResolver.resolve(candidates,
      profile: configuration.profile, preference: .hardwareRequired)) { error in
      XCTAssertEqual(error as? HEVCRecordingError, .hardwareEncoderUnavailable(configuration.profile))
    }
  }

  func testStopDrainsSyntheticBuffersBeforeFinalization() throws {
    let writer = SyntheticSourceWriter()
    let recorder = try SourceRecorderCore(configuration: configuration(
      feed: "finalization", url: URL(fileURLWithPath: "/tmp/finalization.mov")), writerFactory: { writer })
    try recorder.start()
    let duration = RecordingFrameRate.fps5994.frameDuration
    for index in 0..<20 {
      let pts = CMTimeMultiply(duration, multiplier: Int32(index))
      XCTAssertTrue(recorder.appendVideo(try videoSample(at: pts, duration: duration)))
      XCTAssertTrue(recorder.appendAudio(try audioSample(at: CMTime(value: Int64(index) * 800,
        timescale: 48_000))))
    }
    try recorder.stop()
    XCTAssertTrue(writer.finished)
    XCTAssertEqual(recorder.telemetry.appendedVideo, 20)
    XCTAssertEqual(recorder.telemetry.appendedAudio, 20)
    XCTAssertEqual(recorder.telemetry.totalDrops, 0)
  }

  static let allTests = [
    ("two feeds pause and finalize", testTwoFeedsRecordSimultaneouslyAndFinalizeAfterPauseResume),
    ("audio/video PTS alignment", testAudioAndVideoPTSStayAlignedAtBothCaptureRates),
    ("drop-frame timecode alignment", testDropFrameTimecodeAndSourceAlignmentAtBothRates),
    ("encoder settings", testEncoderSettingsPreserveTenBit422AndSelectionPolicy),
    ("finalization drains buffers", testStopDrainsSyntheticBuffersBeforeFinalization),
  ]
}

private extension Result where Failure: Error {
  var successValue: Success? {
    guard case let .success(value) = self else { return nil }
    return value
  }
}

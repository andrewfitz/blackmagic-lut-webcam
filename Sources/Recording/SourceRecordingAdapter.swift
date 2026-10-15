import CoreMedia
import CoreVideo
import Foundation

/// Bridges the Blackmagic capture callback boundary to one source recorder.
///
/// The adapter deliberately has no image-processing policy. A callback's
/// `CVPixelBuffer` is retained by the resulting sample buffer and handed to
/// `SourceRecorderCore` without locking, copying, scaling, LUT application, or
/// pixel-format conversion. Audio sample buffers are forwarded unchanged. A
/// caller that receives a raw embedded packet can use the packet overload;
/// packet conversion is kept in `EmbeddedAudioRecording` where its format
/// contract is defined.
final class SourceRecordingCallbackAdapter: @unchecked Sendable {
  let feedID: SourceRecordingFeedID
  private let recorder: SourceRecorderCore

  init(feedID: SourceRecordingFeedID, recorder: SourceRecorderCore) {
    self.feedID = feedID
    self.recorder = recorder
  }

  init(configuration: SourceRecordingConfiguration,
    writerFactory: @escaping SourceRecorderCore.WriterFactory) throws {
    feedID = configuration.feedID
    recorder = try SourceRecorderCore(configuration: configuration,
      writerFactory: writerFactory)
  }

  convenience init(configuration: SourceRecordingConfiguration) throws {
    try self.init(feedID: configuration.feedID,
      recorder: SourceRecorderCore(configuration: configuration))
  }

  var state: SourceRecordingState { recorder.state }
  var telemetry: SourceRecordingTelemetry { recorder.telemetry }

  func start() throws { try recorder.start() }
  func pause() throws { try recorder.pause() }
  func resume() throws { try recorder.resume() }
  func stop() throws { try recorder.stop() }

  /// Appends the sample supplied by an upstream source callback without
  /// replacing its image buffer, format description, timing, or attachments.
  @discardableResult
  func appendRawVideo(sample: CMSampleBuffer) -> Bool {
    recorder.appendVideo(sample)
  }

  /// Convenience spelling for callback code that already owns a sample.
  @discardableResult
  func appendRawVideo(_ sample: CMSampleBuffer) -> Bool {
    appendRawVideo(sample: sample)
  }

  /// Wraps the original Blackmagic pixel buffer in a timed sample. Core Media
  /// retains the original buffer; no image bytes are read or transformed.
  /// `signalValid` mirrors the backend callback and rejects no-signal frames.
  @discardableResult
  func appendRawVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime, signalValid: Bool = true) -> Bool {
    guard signalValid else { return false }
    guard presentationTime.isValid, presentationTime.isNumeric,
      duration.isValid, duration.isNumeric, duration.value > 0 else {
      return false
    }
    guard let sample = Self.makeSample(pixelBuffer: pixelBuffer,
      presentationTime: presentationTime, duration: duration) else {
      return false
    }
    return recorder.appendVideo(sample)
  }

  /// Accepts a Blackmagic frame callback using the unlabeled buffer spelling.
  @discardableResult
  func appendRawVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime, signalValid: Bool = true) -> Bool {
    appendRawVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime,
      duration: duration, signalValid: signalValid)
  }

  /// Forwards an embedded audio CMSampleBuffer without changing bytes or
  /// timing. The recorder retains the sample until its callback queue drains.
  @discardableResult
  func appendEmbeddedAudio(sample: CMSampleBuffer) -> Bool {
    recorder.appendAudio(sample)
  }

  @discardableResult
  func appendEmbeddedAudio(_ sample: CMSampleBuffer) -> Bool {
    appendEmbeddedAudio(sample: sample)
  }

  /// Builds the Core Media sample for an embedded packet, then forwards it to
  /// the recorder. The packet overload is useful directly from a Blackmagic
  /// audio callback that has copied its bounded PCM payload.
  @discardableResult
  func appendEmbeddedAudio(packet: EmbeddedAudioPacket) -> Bool {
    guard let sample = try? EmbeddedAudioRecording.makeSampleBuffer(for: packet) else {
      return false
    }
    return recorder.appendAudio(sample)
  }

  @discardableResult
  func appendEmbeddedAudio(_ packet: EmbeddedAudioPacket) -> Bool {
    appendEmbeddedAudio(packet: packet)
  }

  /// Copies one bounded Blackmagic PCM payload into the embedded-audio packet
  /// contract and queues its exact source timestamp. Invalid packet metadata
  /// is rejected before anything reaches the writer.
  @discardableResult
  func appendEmbeddedAudio(sourcePCM32: Data, sampleFrameCount: Int,
    presentationTime: CMTime,
    channelCount: Int = EmbeddedAudioFormat.channelCount) -> Bool {
    guard let packet = try? EmbeddedAudioPacket(sourcePCM32: sourcePCM32,
      sampleFrameCount: sampleFrameCount, presentationTime: presentationTime,
      channelCount: channelCount) else { return false }
    return appendEmbeddedAudio(packet: packet)
  }

  /// Returns the adapter's raw callback closures. They capture this adapter,
  /// preserving the per-feed routing while leaving callback callers free to
  /// pass them to a backend without any controller changes.
  var callbacks: Callbacks {
    Callbacks(
      video: { [weak self] pixelBuffer, presentationTime, duration, signalValid in
        self?.appendRawVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime,
          duration: duration, signalValid: signalValid) ?? false
      },
      audio: { [weak self] sample in self?.appendEmbeddedAudio(sample: sample) ?? false })
  }

  struct Callbacks: @unchecked Sendable {
    let video: @Sendable (CVPixelBuffer, CMTime, CMTime, Bool) -> Bool
    let audio: @Sendable (CMSampleBuffer) -> Bool
  }

  private static func makeSample(pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription) == noErr,
      let formatDescription else { return nil }

    var timing = CMSampleTimingInfo(duration: duration,
      presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: formatDescription, sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard status == noErr else { return nil }
    return sample
  }
}

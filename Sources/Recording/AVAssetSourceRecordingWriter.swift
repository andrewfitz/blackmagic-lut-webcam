import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// AVAssetWriter/VideoToolbox implementation for one source feed. Source
/// pixel buffers are handed directly to VideoToolbox; this type does not lock,
/// copy, convert, or otherwise process image pixels.
final class AVAssetSourceRecordingWriter: SourceRecordingWriter {
  private let configuration: SourceRecordingConfiguration
  private let lock = NSRecursiveLock()
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var timecodeInput: AVAssetWriterInput?
  private var timecodeTrack: QuickTimeTimecodeTrack?
  private var timecodeSession: RecordingTimecodeSession?
  private var compressionSession: VTCompressionSession?
  private var telemetryValue = SourceRecordingWriterTelemetry()
  private var started = false
  private var sessionStarted = false
  private var finishing = false
  private var finished = false
  private var lastVideoPTS: CMTime?
  private var lastAudioPTS: CMTime?
  private var pendingAudio: [CMSampleBuffer] = []
  private static let pendingAudioCapacity = 64

  init(configuration: SourceRecordingConfiguration) throws {
    self.configuration = configuration
  }

  /// Returns the generated track description for modes that do not depend on
  /// an embedded source timecode. Source mode remains absent until the capture
  /// boundary supplies a source timecode value.
  static func makeTimecodeTrack(for configuration: SourceRecordingConfiguration) throws
    -> QuickTimeTimecodeTrack? {
    guard configuration.timecodePolicy != .source else { return nil }
    return try QuickTimeTimecodeTrack(frameRate: configuration.frameRate,
      dropFrame: configuration.timecodeDropFrame)
  }

  var telemetry: SourceRecordingWriterTelemetry { lock.withLock { telemetryValue } }

  deinit {
    if let compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
    }
  }

  /// Admission starts the writer lazily. A pass-through AVAssetWriter input
  /// needs a compressed format hint, which is available only after the first
  /// VideoToolbox callback; delaying file initialization preserves that hint
  /// and avoids a format-conversion path.
  func start() throws {
    try lock.withLock {
      guard !started else { throw SourceRecordingError.invalidState(.recording, operation: "start writer") }
      started = true
    }
  }

  func appendVideo(_ sample: CMSampleBuffer) throws {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
      throw SourceRecordingError.unsupportedSample("A video sample has no image buffer.")
    }
    guard CVPixelBufferGetPixelFormatType(imageBuffer) == configuration.videoProfile.sourcePixelFormat else {
      throw SourceRecordingError.unsupportedSample(
        "The source recorder requires native 10-bit 4:2:2 video for \(configuration.videoProfile.displayName).")
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    guard pts.isNumeric else {
      throw SourceRecordingError.unsupportedSample("A video sample has no numeric presentation time.")
    }
    try lock.withLock {
      try ensureCanAppend()
      if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) < 0 {
        throw SourceRecordingError.unsupportedSample("Video timestamps moved backwards.")
      }
      try ensureCompressionSession(for: imageBuffer)
      guard let compressionSession else {
        throw SourceRecordingError.writerFailure("VideoToolbox compression session is unavailable.")
      }
      var flags = VTEncodeInfoFlags()
      let status = VTCompressionSessionEncodeFrame(compressionSession, imageBuffer: imageBuffer,
        presentationTimeStamp: pts, duration: CMSampleBufferGetDuration(sample), frameProperties: nil,
        sourceFrameRefcon: nil, infoFlagsOut: &flags)
      guard status == noErr else {
        throw SourceRecordingError.writerFailure("VideoToolbox encode failed (OSStatus \(status)).")
      }
      lastVideoPTS = pts
    }
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    guard pts.isNumeric else {
      throw SourceRecordingError.unsupportedSample("An audio sample has no numeric presentation time.")
    }
    try lock.withLock {
      try ensureCanAppend()
      if let lastAudioPTS, CMTimeCompare(pts, lastAudioPTS) < 0 {
        throw SourceRecordingError.unsupportedSample("Audio timestamps moved backwards.")
      }
      // Video establishes the pass-through format hint and therefore must be
      // admitted before audio starts the file. Keep a bounded early packet
      // queue while VideoToolbox produces its first compressed sample.
      guard let audioInput else {
        guard pendingAudio.count < Self.pendingAudioCapacity else {
          throw SourceRecordingError.writerNotReady("Video has not established the pass-through format hint.")
        }
        pendingAudio.append(sample)
        lastAudioPTS = pts
        return
      }
      try ensureSession(at: pts)
      guard Self.inputIsReady(audioInput) else {
        throw SourceRecordingError.writerNotReady("Audio writer input is not ready.")
      }
      guard Self.append(sample, to: audioInput) else {
        throw Self.writerError(writer, fallback: "Audio sample append failed.")
      }
      lastAudioPTS = pts
    }
  }

  func finish() throws {
    let compressionSession = try lock.withLock { () -> VTCompressionSession? in
      guard started, !finished else { return nil }
      finishing = true
      return self.compressionSession
    }
    // CompleteFrames synchronously invokes the VideoToolbox callback. Never
    // hold `lock` here: the callback needs the same lock to append its final
    // compressed sample, otherwise stop deadlocks indefinitely on HEVC.
    if let compressionSession {
      let status = VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      guard status == noErr else {
        lock.withLock { finished = true; finishing = false }
        throw SourceRecordingError.writerFailure("VideoToolbox flush failed (OSStatus \(status)).")
      }
    }
    let writer = try lock.withLock { () -> AVAssetWriter? in
      guard pendingAudio.isEmpty else {
        finished = true
        finishing = false
        throw SourceRecordingError.writerFailure("VideoToolbox finished before the audio input was established.")
      }
      guard let writer else {
        finished = true
        finishing = false
        return nil
      }
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      timecodeInput?.markAsFinished()
      finished = true
      finishing = false
      return writer
    }
    guard let writer else { return }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if writer.status == .failed {
      throw Self.writerError(writer, fallback: "AVAssetWriter finish failed.")
    }
  }

  private func ensureCanAppend() throws {
    guard started else { throw SourceRecordingError.invalidState(.idle, operation: "append sample") }
    guard !finished, !finishing else { throw SourceRecordingError.invalidState(.stopping, operation: "append sample") }
  }

  private func ensureSession(at time: CMTime) throws {
    guard let writer else { throw SourceRecordingError.writerFailure("AVAssetWriter has not been initialized.") }
    if !sessionStarted {
      guard writer.status == .writing else {
        throw Self.writerError(writer, fallback: "AVAssetWriter is not writing.")
      }
      writer.startSession(atSourceTime: time)
      sessionStarted = true
    }
  }

  private func ensureWriter(videoFormat: CMFormatDescription) throws {
    guard writer == nil else { return }
    let writer: AVAssetWriter
    do {
      let parent = configuration.outputURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: configuration.fileType)
    } catch {
      throw SourceRecordingError.writerFailure(error.localizedDescription)
    }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    // Declare the exact packed 48 kHz / 24-bit source format. Passing nil
    // leaves AVAssetWriter free to choose a converter and can silently reject
    // the packed 24-bit CMSampleBuffers produced from DeckLink PCM.
    let audio = AVAssetWriterInput(mediaType: .audio,
      outputSettings: EmbeddedAudioFormat.assetWriterSettings)
    let generatedTimecodeTrack = try Self.makeTimecodeTrack(for: configuration)
    let timecode = generatedTimecodeTrack?.makeInput()
    video.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    audio.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    timecode?.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    guard writer.canAdd(video), writer.canAdd(audio),
      timecode.map({ writer.canAdd($0) }) ?? true else {
      throw SourceRecordingError.writerFailure("The output container cannot add source tracks.")
    }
    Self.invokeAddInput(writer, input: video)
    Self.invokeAddInput(writer, input: audio)
    if let timecode {
      Self.invokeAddInput(writer, input: timecode)
      video.addTrackAssociation(withTrackOf: timecode,
        type: AVAssetTrack.AssociationType.timecode.rawValue)
    }
    guard Self.invokeStartWriting(writer) else {
      throw Self.writerError(writer, fallback: "AVAssetWriter could not start writing.")
    }
    self.writer = writer
    self.videoInput = video
    self.audioInput = audio
    self.timecodeInput = timecode
    self.timecodeTrack = generatedTimecodeTrack
    if generatedTimecodeTrack != nil {
      self.timecodeSession = RecordingTimecodeSession(
        frameRate: configuration.frameRate,
        dropFrame: configuration.timecodeDropFrame,
        policy: configuration.timecodePolicy,
        startDate: configuration.timecodeStartDate,
        sourceStartTime: configuration.timecodeSourceStartTime)
    }
  }

  private func ensureCompressionSession(for imageBuffer: CVImageBuffer) throws {
    guard compressionSession == nil else { return }
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    guard width == configuration.width, height == configuration.height else {
      throw SourceRecordingError.unsupportedSample(
        "Video dimensions \(width) × \(height) do not match the configured source \(configuration.width) × \(configuration.height).")
    }
    var session: VTCompressionSession?
    let encoderSpecification = configuration.videoProfile.encoderSpecification
    let imageBufferAttributes: CFDictionary = [
      kCVPixelBufferPixelFormatTypeKey: configuration.videoProfile.sourcePixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ] as CFDictionary
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
      width: Int32(width), height: Int32(height), codecType: configuration.videoCodec,
      encoderSpecification: encoderSpecification, imageBufferAttributes: imageBufferAttributes,
      compressedDataAllocator: nil,
      outputCallback: sourceRecordingCompressionCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
    guard status == noErr, let session else {
      throw SourceRecordingError.writerFailure("VideoToolbox could not create a compression session (OSStatus \(status)).")
    }
    if configuration.realTimeEncoding {
      guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
        value: kCFBooleanTrue) == noErr else {
        VTCompressionSessionInvalidate(session)
        throw SourceRecordingError.writerFailure(
          "VideoToolbox rejected real-time encoding for \(configuration.videoProfile.displayName).")
      }
    }
    // ProRes encoders on macOS expose a fixed no-reordering policy and reject
    // this property even though their output is already intra-frame. HEVC
    // must accept it because the source recorder relies on deterministic PTS.
    let noReorderingStatus = VTSessionSetProperty(session,
      key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    if configuration.videoProfile.codecType == kCMVideoCodecType_HEVC,
      noReorderingStatus != noErr {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox rejected the no-reordering source contract.")
    }
    let keyFrameInterval = configuration.maxKeyFrameInterval as CFTypeRef
    let keyFrameStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: keyFrameInterval)
    if configuration.videoProfile.codecType == kCMVideoCodecType_HEVC,
      keyFrameStatus != noErr {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox rejected the source key-frame interval.")
    }
    if let profileLevel = configuration.videoProfile.profileLevel {
      guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
        value: profileLevel as CFString) == noErr else {
        VTCompressionSessionInvalidate(session)
        throw SourceRecordingError.writerFailure(
          "VideoToolbox rejected profile \(profileLevel) for \(configuration.videoProfile.displayName).")
      }
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox could not prepare the encoder (OSStatus \(prepareStatus)).")
    }
    compressionSession = session
  }

  private static func invokeStartWriting(_ writer: AVAssetWriter) -> Bool {
    let selector = NSSelectorFromString("startWriting")
    guard let implementation = writer.method(for: selector) else { return false }
    typealias Function = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(implementation, to: Function.self)(writer, selector)
  }

  private static func invokeAddInput(_ writer: AVAssetWriter, input: AVAssetWriterInput) {
    let selector = NSSelectorFromString("addInput:")
    guard let implementation = writer.method(for: selector) else { return }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    unsafeBitCast(implementation, to: Function.self)(writer, selector, input)
  }

  private static func inputIsReady(_ input: AVAssetWriterInput) -> Bool {
    (input.value(forKey: "readyForMoreMediaData") as? NSNumber)?.boolValue ?? false
  }

  private static func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
    let selector = NSSelectorFromString("appendSampleBuffer:")
    guard let implementation = input.method(for: selector) else { return false }
    typealias Function = @convention(c) (AnyObject, Selector, CMSampleBuffer) -> Bool
    return unsafeBitCast(implementation, to: Function.self)(input, selector, sample)
  }

  private static func writerError(_ writer: AVAssetWriter?, fallback: String) -> SourceRecordingError {
    .writerFailure(writer?.error?.localizedDescription ?? fallback)
  }

  fileprivate func recordEncoderFailure(status: OSStatus) {
    lock.withLock {
      telemetryValue.droppedEncodedVideo &+= 1
      telemetryValue.encoderErrors &+= 1
      telemetryValue.lastError = "VideoToolbox callback failed (OSStatus \(status))."
    }
  }

  fileprivate func appendEncodedVideo(_ sample: CMSampleBuffer) {
    lock.withLock {
      do {
        guard !finished else {
          telemetryValue.droppedEncodedVideo &+= 1
          return
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
          throw SourceRecordingError.unsupportedSample("VideoToolbox returned a sample without a format description.")
        }
        try ensureWriter(videoFormat: format)
        guard let videoInput else { throw SourceRecordingError.writerFailure("Video writer input is unavailable.") }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        try ensureSession(at: pts)
        guard Self.inputIsReady(videoInput) else {
          telemetryValue.droppedEncodedVideo &+= 1
          telemetryValue.encoderErrors &+= 1
          telemetryValue.lastError = SourceRecordingError.writerNotReady("Video writer input is not ready.").localizedDescription
          return
        }
        guard Self.append(sample, to: videoInput) else {
          throw Self.writerError(writer, fallback: "Video sample append failed.")
        }
        telemetryValue.encodedVideo &+= 1
        try appendTimecode(for: pts)
        if let audioInput {
          while let pendingAudio = self.pendingAudio.first {
            guard Self.inputIsReady(audioInput) else { break }
            guard Self.append(pendingAudio, to: audioInput) else {
              throw Self.writerError(writer, fallback: "Pending audio sample append failed.")
            }
            self.pendingAudio.removeFirst()
          }
        }
      } catch {
        telemetryValue.droppedEncodedVideo &+= 1
        telemetryValue.encoderErrors &+= 1
        telemetryValue.lastError = error.localizedDescription
      }
    }
  }

  private func appendTimecode(for sourcePTS: CMTime) throws {
    guard let timecodeInput, let timecodeTrack, let timecodeSession else { return }
    guard Self.inputIsReady(timecodeInput) else {
      throw SourceRecordingError.writerNotReady("Timecode writer input is not ready.")
    }
    guard let value = timecodeSession.timecode(for: sourcePTS) else {
      throw SourceRecordingError.unsupportedSample("The source timestamp cannot be mapped to timecode.")
    }
    let sample = try timecodeTrack.sample(for: value, at: sourcePTS)
    guard Self.append(sample, to: timecodeInput) else {
      throw Self.writerError(writer, fallback: "Timecode sample append failed.")
    }
  }
}

private func sourceRecordingCompressionCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags,
  sampleBuffer: CMSampleBuffer?) {
  guard let outputCallbackRefCon else { return }
  let writer = Unmanaged<AVAssetSourceRecordingWriter>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
  guard status == noErr, let sampleBuffer else {
    writer.recordEncoderFailure(status: status)
    return
  }
  writer.appendEncodedVideo(sampleBuffer)
}

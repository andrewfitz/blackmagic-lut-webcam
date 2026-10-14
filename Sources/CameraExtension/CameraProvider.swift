@preconcurrency import CoreMedia
@preconcurrency import CoreMediaIO
import CoreVideo
import IOKit.audio
import Foundation
import os

typealias CameraSampleCompletion = @Sendable (CMSampleBuffer?, UInt64,
  CMIOExtensionStream.DiscontinuityFlags, Bool, Error?) -> Void
typealias CameraSampleRequest = (@escaping CameraSampleCompletion) -> Void

// Provider API calls, resource state and timers live on this serial queue.
// Transport injection permits the actual stream lifecycle to run in-process;
// tests never register or install the unsigned system extension.
final class CameraProvider: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
  let queue = DispatchQueue(label: "org.ultrastudiolut.camera")
  var provider: CMIOExtensionProvider!
  var device: CMIOExtensionDevice!
  let deviceSource = CameraDeviceSource()
  var source: CameraStream!
  var sink: CameraStream!
  private(set) var activeIndex = 0
  private(set) var duration = VideoContract.fastDuration
  private(set) var latest: CVPixelBuffer?
  private(set) var receivedAt: CMTime = .invalid
  var consumers = 0
  private var black: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var lastOutput: CMTime = .invalid
  private var nextStandby: CMTime = .invalid
  private var wasStandby = true
  let automaticTimers: Bool
  let clock: () -> CMTime
  private let output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)?
  let logger = Logger(subsystem: VideoContract.extensionID, category: "camera")
  private(set) var formats: [CMIOExtensionStreamFormat] = []

  init(automaticTimers: Bool = true, createNativeProvider: Bool = true,
    clock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
    output: ((CMSampleBuffer, CMIOExtensionStream.DiscontinuityFlags, UInt64) -> Void)? = nil) {
    self.automaticTimers = automaticTimers
    self.clock = clock
    self.output = output
    super.init()
    do {
      for (width, height) in [(1920, 1080), (3840, 2160)] {
        for type in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] + VideoContract.tenBit422 {
          let description = try VideoContract.formatDescription(width: width, height: height, pixelFormat: type)
          formats.append(CMIOExtensionStreamFormat(formatDescription: description,
            maxFrameDuration: VideoContract.slowDuration, minFrameDuration: VideoContract.fastDuration,
            validFrameDurations: [VideoContract.slowDuration, VideoContract.fastDuration]))
        }
      }
      // CMIOExtensionProvider is a process singleton. In-process tests create
      // native streams/devices but omit a second native provider registration.
      if createNativeProvider { provider = CMIOExtensionProvider(source: self, clientQueue: queue) }
      device = CMIOExtensionDevice(localizedName: VideoContract.cameraName,
        deviceID: UUID(uuidString: "93720F52-DB02-4DF3-A9D8-F86BD97F44AA")!,
        legacyDeviceID: VideoContract.deviceUID, source: deviceSource)
      source = CameraStream(owner: self, isSink: false)
      sink = CameraStream(owner: self, isSink: true)
      try device.addStream(source.stream)
      try device.addStream(sink.stream)
      if let provider { try provider.addDevice(device) }
    } catch { fatalError("Cannot publish virtual camera: \(error)") }
  }

  deinit { timer?.cancel() }

  var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
  func connect(to client: CMIOExtensionClient) throws {}
  func disconnect(from client: CMIOExtensionClient) {
    if sink.client == client { sink.stopConsumption() }
  }
  func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
    let result = CMIOExtensionProviderProperties(dictionary: [:])
    result.manufacturer = "UltraStudio LUT"
    return result
  }
  func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}

  func setProperties(index: Int?, frameDuration: CMTime?) throws {
    let nextIndex = index ?? activeIndex
    guard formats.indices.contains(nextIndex) else { throw VideoError.message("Unsupported camera format.") }
    let nextDuration: CMTime
    if let requested = frameDuration {
      guard requested.isNumeric, requested.epoch == 0 else { throw VideoError.message("Use 29.97 or 59.94 fps.") }
      if abs(requested.seconds - VideoContract.slowDuration.seconds) < 0.000001 {
        nextDuration = VideoContract.slowDuration
      } else if abs(requested.seconds - VideoContract.fastDuration.seconds) < 0.000001 {
        nextDuration = VideoContract.fastDuration
      } else { throw VideoError.message("Use 29.97 or 59.94 fps.") }
    } else { nextDuration = duration }
    // Validate the complete request before modifying either property. The host
    // selects the common source/sink contract before starting the producer.
    guard !sink.consuming || (nextIndex == activeIndex && nextDuration == duration) else {
      throw VideoError.message("Stop capture in UltraStudio LUT before changing the output format or frame rate.")
    }
    var changes: [CMIOExtensionProperty: CMIOExtensionPropertyState<AnyObject>] = [:]
    if nextIndex != activeIndex {
      activeIndex = nextIndex
      latest = nil
      receivedAt = .invalid
      black = nil
      changes[.streamActiveFormatIndex] = CMIOExtensionPropertyState(value: NSNumber(value: nextIndex))
    }
    if nextDuration != duration {
      duration = nextDuration
      changes[.streamFrameDuration] = CMIOExtensionPropertyState(value: CMTimeCopyAsDictionary(nextDuration, allocator: kCFAllocatorDefault))
    }
    if !changes.isEmpty {
      source.stream.notifyPropertiesChanged(changes)
      sink.stream.notifyPropertiesChanged(changes)
      restartTimer()
    }
  }

  func restartTimer() {
    timer?.cancel()
    timer = nil
    nextStandby = .invalid
    guard consumers > 0 else {
      lastOutput = .invalid
      return
    }
    guard automaticTimers else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.emitStandby() }
    self.timer = timer
    timer.resume()
  }

  // Live frames already have the selected capture cadence. Forward them once,
  // preserving metadata and timestamps, instead of sampling latest on another
  // free-running clock (which duplicates and drops live frames).
  @discardableResult
  func receive(_ sample: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags) -> Bool {
    guard CMSampleBufferDataIsReady(sample), let image = CMSampleBufferGetImageBuffer(sample) else { return false }
    guard (try? VideoBufferLayout.validate(image)) != nil else { return false }
    let expected = formats[activeIndex].formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(expected)
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    let sampleDuration = CMSampleBufferGetDuration(sample)
    guard CVPixelBufferGetWidth(image) == dimensions.width,
      CVPixelBufferGetHeight(image) == dimensions.height,
      CVPixelBufferGetPixelFormatType(image) == CMFormatDescriptionGetMediaSubType(expected),
      time.isNumeric, time.epoch == 0, time.seconds >= 0,
      sampleDuration.isNumeric, abs(sampleDuration.seconds - duration.seconds) < 0.000001 else { return false }
    latest = image
    receivedAt = clock()
    nextStandby = .invalid
    guard consumers > 0 else { return true }
    do {
      var outgoing = sample
      var flags = discontinuity
      if wasStandby { flags.insert(.time) }
      // A queued capture frame may predate the last standby frame on recovery.
      // Repair only that boundary; live frames keep their producer timestamps.
      if lastOutput.isNumeric, CMTimeCompare(time, lastOutput) <= 0 {
        let now = clock()
        let adjusted = CMTimeCompare(now, lastOutput) > 0 ? now : CMTimeAdd(lastOutput, duration)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: adjusted, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
          sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw VideoError.message("Cannot repair source timestamp (\(status)).") }
        outgoing = copy
        flags.insert(.time)
      }
      wasStandby = false
      send(outgoing, discontinuity: flags)
      return true
    } catch {
      logger.error("Camera output failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func clearInput() {
    latest = nil
    receivedAt = .invalid
    nextStandby = .invalid
  }

  func emitStandby() {
    guard consumers > 0 else { return }
    let now = clock()
    guard now.isNumeric else { return }
    if receivedAt.isNumeric, CMTimeSubtract(now, receivedAt).seconds < 0.5 { return }
    do {
      latest = nil
      if black == nil { black = try makeBlack() }
      guard let black else { return }
      if !nextStandby.isNumeric {
        nextStandby = CMTimeConvertScale(now, timescale: 60_000, method: .roundTowardZero)
      }
      if lastOutput.isNumeric, CMTimeCompare(nextStandby, lastOutput) <= 0 {
        nextStandby = CMTimeAdd(lastOutput, duration)
      }
      guard CMTimeCompare(now, nextStandby) >= 0 else { return }
      // Skip late timer slots instead of bursting queued standby frames.
      let lateness = CMTimeSubtract(now, nextStandby).seconds
      if lateness >= duration.seconds {
        let missed = Int32(min(floor(lateness / duration.seconds), Double(Int32.max)))
        nextStandby = CMTimeAdd(nextStandby, CMTimeMultiply(duration, multiplier: missed))
      }
      let sample = try VideoContract.sample(black, at: nextStandby, duration: duration)
      send(sample, discontinuity: wasStandby ? [] : [.time])
      wasStandby = true
      nextStandby = CMTimeAdd(nextStandby, duration)
    } catch { logger.error("Camera output failed: \(error.localizedDescription, privacy: .public)") }
  }

  private func send(_ sample: CMSampleBuffer, discontinuity: CMIOExtensionStream.DiscontinuityFlags) {
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    lastOutput = time
    let nanoseconds = UInt64(max(0, CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value))
    if let output { output(sample, discontinuity, nanoseconds) }
    else { source.stream.send(sample, discontinuity: discontinuity, hostTimeInNanoseconds: nanoseconds) }
  }

  private func makeBlack() throws -> CVPixelBuffer {
    let description = formats[activeIndex].formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let type = CMFormatDescriptionGetMediaSubType(description)
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(dimensions.width), Int(dimensions.height), type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else { throw VideoError.message("Cannot allocate standby image.") }
    guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw VideoError.message("Cannot fill standby image.") }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    if CVPixelBufferIsPlanar(result) {
      for plane in 0..<CVPixelBufferGetPlaneCount(result) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else { continue }
        let length = CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane)
        if type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
          memset(base, plane == 0 ? 16 : 128, length)
        } else {
          let value: UInt16 = plane == 0 ? (type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 0 : 64 << 6) : 512 << 6
          base.assumingMemoryBound(to: UInt16.self).initialize(repeating: value, count: length / 2)
        }
      }
    } else if let base = CVPixelBufferGetBaseAddress(result) {
      let count = CVPixelBufferGetBytesPerRow(result) * CVPixelBufferGetHeight(result) / 4
      let words = base.assumingMemoryBound(to: UInt32.self)
      let pattern: [UInt32] = [512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20),
        512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20)]
      for i in 0..<count { words[i] = pattern[i % 4] }
    }
    CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return result
  }
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
  var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
  func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
    let result = CMIOExtensionDeviceProperties(dictionary: [:])
    result.transportType = kIOAudioDeviceTransportTypeVirtual
    result.model = "FX3 LUT camera"
    return result
  }
  func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}

final class CameraStream: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
  unowned let owner: CameraProvider
  let isSink: Bool
  var stream: CMIOExtensionStream!
  private(set) var client: CMIOExtensionClient?
  private(set) var consuming = false
  private(set) var consumePending = false
  private var generation: UInt64 = 0
  private var timer: DispatchSourceTimer?
  private var request: CameraSampleRequest?

  init(owner: CameraProvider, isSink: Bool) {
    self.owner = owner
    self.isSink = isSink
    super.init()
    stream = CMIOExtensionStream(localizedName: isSink ? VideoContract.sinkName : VideoContract.cameraName,
      streamID: UUID(uuidString: isSink ? "4757380D-BB4D-4E9A-8DBA-B55BE803416E" : "CC10288A-B4DC-4AA5-8072-6791119C1547")!,
      direction: isSink ? .sink : .source, clockType: .hostTime, source: self)
  }
  deinit { timer?.cancel() }

  var formats: [CMIOExtensionStreamFormat] { owner.formats }
  var availableProperties: Set<CMIOExtensionProperty> {
    var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
    if isSink { properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkEndOfData]) }
    return properties
  }
  func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
    let result = CMIOExtensionStreamProperties(dictionary: [:])
    result.activeFormatIndex = owner.activeIndex
    result.frameDuration = owner.duration
    if isSink {
      result.sinkBufferQueueSize = 3
      result.sinkBuffersRequiredForStartup = 1
      result.sinkEndOfData = 0
    }
    return result
  }
  func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
    try owner.setProperties(index: properties.activeFormatIndex, frameDuration: properties.frameDuration)
  }
  func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
    if isSink {
      guard client.signingID == "org.ultrastudiolut.app" else { return false }
      guard self.client == nil || self.client == client else { return false }
      self.client = client
    }
    return true
  }
  func startStream() throws {
    if isSink {
      guard let client else { throw VideoError.message("Missing camera producer.") }
      beginConsumption { [weak self] completion in
        self?.stream.consumeSampleBuffer(from: client, completionHandler: completion)
      }
    } else {
      owner.consumers += 1
      // An additional viewer does not reset the clock of existing viewers.
      if owner.consumers == 1 { owner.restartTimer() }
    }
  }
  func stopStream() throws {
    if isSink { stopConsumption() }
    else {
      owner.consumers = max(0, owner.consumers - 1)
      if owner.consumers == 0 { owner.restartTimer() }
    }
  }

  func beginConsumption(_ request: @escaping CameraSampleRequest) {
    guard isSink, !consuming else { return }
    consuming = true
    consumePending = false
    generation &+= 1
    self.request = request
    guard owner.automaticTimers else { return }
    let timer = DispatchSource.makeTimerSource(queue: owner.queue)
    // Poll at twice the selected frame rate, draining ready frames immediately.
    // This bounds ingress latency without a fixed 250 Hz wakeup rate.
    timer.schedule(deadline: .now(), repeating: owner.duration.seconds / 2, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.consume() }
    self.timer = timer
    timer.resume()
  }
  func stopConsumption() {
    consuming = false
    consumePending = false
    generation &+= 1
    timer?.cancel()
    timer = nil
    request = nil
    client = nil
    owner.clearInput()
  }
  func consume() {
    guard consuming, !consumePending, let request else { return }
    consumePending = true
    let requestedGeneration = generation
    request { [weak self] sample, sequence, discontinuity, hasMore, error in
      guard let self else { return }
      // Strongly retain the immutable callback sample across asynchronous hop.
      let received = ReceivedSample(sample: sample)
      self.owner.queue.async {
        // Old callbacks must neither clear a new request nor publish old footage.
        guard self.consuming, self.generation == requestedGeneration else { return }
        self.consumePending = false
        if let sample = received.sample {
          if !self.owner.receive(sample, discontinuity: discontinuity) {
            self.owner.logger.error("Camera input did not match the negotiated format, frame rate or timestamp.")
          }
          self.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence,
            hostTimeInNanoseconds: UInt64(max(0, CMTimeConvertScale(self.owner.clock(), timescale: 1_000_000_000, method: .default).value))))
        }
        if let error { self.owner.logger.error("Camera input failed: \(error.localizedDescription, privacy: .public)") }
        if hasMore && received.sample != nil && error == nil { self.consume() }
      }
    }
  }
}

private struct ReceivedSample: @unchecked Sendable {
  let sample: CMSampleBuffer?
}

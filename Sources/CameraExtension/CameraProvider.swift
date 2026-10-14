@preconcurrency import CoreMedia
@preconcurrency import CoreMediaIO
import CoreVideo
import IOKit.audio
import Foundation
import os

// Provider API calls and timers are confined to the provider's serial queue.
final class CameraProvider: NSObject, CMIOExtensionProviderSource, CMIOExtensionDeviceSource, @unchecked Sendable {
  let queue = DispatchQueue(label: "org.ultrastudiolut.camera")
  var provider: CMIOExtensionProvider!
  var device: CMIOExtensionDevice!
  var source: CameraStream!
  var sink: CameraStream!
  var activeIndex = 0
  var duration = VideoContract.fastDuration
  var latest: CVPixelBuffer?
  var receivedAt: Double = 0
  var consumers = 0
  var black: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  let logger = Logger(subsystem: VideoContract.extensionID, category: "camera")
  var formats: [CMIOExtensionStreamFormat] = []

  override init() {
    super.init()
    do {
      // Publish both Zoom-compatible and full-precision modes. The host selects
      // the same format on source and sink before capture starts.
      for (width, height) in [(1920, 1080), (3840, 2160)] {
        for type in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] + VideoContract.tenBit422 {
          let description = try VideoContract.formatDescription(width: width, height: height, pixelFormat: type)
          formats.append(CMIOExtensionStreamFormat(formatDescription: description,
            maxFrameDuration: VideoContract.slowDuration, minFrameDuration: VideoContract.fastDuration,
            validFrameDurations: [VideoContract.slowDuration, VideoContract.fastDuration]))
        }
      }
      provider = CMIOExtensionProvider(source: self, clientQueue: queue)
      device = CMIOExtensionDevice(localizedName: VideoContract.cameraName,
        deviceID: UUID(uuidString: "93720F52-DB02-4DF3-A9D8-F86BD97F44AA")!,
        legacyDeviceID: VideoContract.deviceUID, source: self)
      source = CameraStream(owner: self, isSink: false)
      sink = CameraStream(owner: self, isSink: true)
      try device.addStream(source.stream)
      try device.addStream(sink.stream)
      try provider.addDevice(device)
    } catch { fatalError("Cannot publish virtual camera: \(error)") }
  }

  var availableProperties: Set<CMIOExtensionProperty> {
    [.providerManufacturer, .deviceTransportType, .deviceModel]
  }
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
  func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
    let result = CMIOExtensionDeviceProperties(dictionary: [:])
    result.transportType = kIOAudioDeviceTransportTypeVirtual
    result.model = "FX3 LUT camera"
    return result
  }
  func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}

  func setFormat(_ index: Int) throws {
    guard formats.indices.contains(index) else { throw VideoError.message("Unsupported camera format.") }
    // A consumer cannot silently change precision while the producer is live.
    guard index == activeIndex || !sink.consuming else {
      throw VideoError.message("Stop capture in UltraStudio LUT before changing the output format.")
    }
    if index != activeIndex {
      activeIndex = index
      latest = nil
      black = nil
      source.stream.notifyPropertiesChanged([.streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: NSNumber(value: index))])
      sink.stream.notifyPropertiesChanged([.streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: NSNumber(value: index))])
    }
  }

  func restartTimer() {
    timer?.cancel()
    timer = nil
    guard consumers > 0 else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.emit() }
    self.timer = timer
    timer.resume()
  }

  private func emit() {
    do {
      let now = ProcessInfo.processInfo.systemUptime
      let input: CVPixelBuffer
      if let latest, now - receivedAt < 0.5 { input = latest }
      else {
        if black == nil { black = try makeBlack() }
        guard let black else { return }
        input = black
      }
      let time = CMClockGetTime(CMClockGetHostTimeClock())
      let sample = try VideoContract.sample(input, at: time, duration: duration)
      source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(time.seconds * 1_000_000_000))
    } catch { logger.error("Camera output failed: \(error.localizedDescription, privacy: .public)") }
  }

  private func makeBlack() throws -> CVPixelBuffer {
    let description = formats[activeIndex].formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let type = CMFormatDescriptionGetMediaSubType(description)
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(dimensions.width), Int(dimensions.height), type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else { throw VideoError.message("Cannot allocate standby image.") }
    CVPixelBufferLockBaseAddress(result, [])
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
      // v210 packs U Y V Y U Y in 10-bit words, with black Y=64 and neutral C=512.
      let count = CVPixelBufferGetBytesPerRow(result) * CVPixelBufferGetHeight(result) / 4
      let words = base.assumingMemoryBound(to: UInt32.self)
      let pattern: [UInt32] = [512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20),
        512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20)]
      for i in 0..<count { words[i] = pattern[i % 4] }
    }
    return result
  }
}

final class CameraStream: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
  unowned let owner: CameraProvider
  let isSink: Bool
  var stream: CMIOExtensionStream!
  var client: CMIOExtensionClient?
  var consuming = false
  private var consumePending = false
  private var generation: UInt64 = 0
  private var timer: DispatchSourceTimer?

  init(owner: CameraProvider, isSink: Bool) {
    self.owner = owner
    self.isSink = isSink
    super.init()
    stream = CMIOExtensionStream(localizedName: isSink ? VideoContract.sinkName : VideoContract.cameraName,
      streamID: UUID(uuidString: isSink ? "4757380D-BB4D-4E9A-8DBA-B55BE803416E" : "CC10288A-B4DC-4AA5-8072-6791119C1547")!,
      direction: isSink ? .sink : .source, clockType: .hostTime, source: self)
  }
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
    if let index = properties.activeFormatIndex { try owner.setFormat(index) }
    if let duration = properties.frameDuration {
      guard duration == VideoContract.slowDuration || duration == VideoContract.fastDuration else {
        throw VideoError.message("Use 29.97 or 59.94 fps.")
      }
      owner.duration = duration
      owner.restartTimer()
    }
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
      guard client != nil else { throw VideoError.message("Missing camera producer.") }
      consuming = true
      generation &+= 1
      let timer = DispatchSource.makeTimerSource(queue: owner.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(4))
      timer.setEventHandler { [weak self] in self?.consume() }
      self.timer = timer
      timer.resume()
    } else {
      owner.consumers += 1
      owner.restartTimer()
    }
  }
  func stopStream() throws {
    if isSink { stopConsumption() }
    else { owner.consumers = max(0, owner.consumers - 1); owner.restartTimer() }
  }
  func stopConsumption() {
    consuming = false
    generation &+= 1
    timer?.cancel()
    timer = nil
    client = nil
    owner.latest = nil
    owner.receivedAt = 0
  }
  private func consume() {
    guard consuming, !consumePending, let client else { return }
    consumePending = true
    let generation = generation
    stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, hasMore, error in
      guard let self else { return }
      let received = ReceivedSample(sample: sample)
      self.owner.queue.async {
        self.consumePending = false
        guard self.consuming, self.generation == generation else { return }
        if let sample = received.sample, let image = CMSampleBufferGetImageBuffer(sample) {
          let expected = self.owner.formats[self.owner.activeIndex].formatDescription
          let dimensions = CMVideoFormatDescriptionGetDimensions(expected)
          if CVPixelBufferGetWidth(image) == dimensions.width,
            CVPixelBufferGetHeight(image) == dimensions.height,
            CVPixelBufferGetPixelFormatType(image) == CMFormatDescriptionGetMediaSubType(expected) {
            self.owner.latest = image
            self.owner.receivedAt = ProcessInfo.processInfo.systemUptime
          }
          self.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence,
            hostTimeInNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)))
        }
        if let error { self.owner.logger.error("Camera input failed: \(error.localizedDescription, privacy: .public)") }
        if hasMore { self.consume() }
      }
    }
  }
}

// CMIO supplies an immutable retained sample; retain it across dispatch to the
// provider queue without claiming mutable capture buffers are generally safe.
private struct ReceivedSample: @unchecked Sendable {
  let sample: CMSampleBuffer?
}

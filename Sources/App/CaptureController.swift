import CoreVideo
import CoreMedia
import Foundation
import os

struct CaptureUpdate: @unchecked Sendable {
  var message: String
  var input = "No signal"
  var output = ""
  var inputFast: Bool?
  var sourceDuration: CMTime?
  var pipelineEnabledApplied: Bool?
  var frames: UInt64 = 0
  var dropped: UInt64 = 0
  var processingMS: Double = 0
  var previewDelivered = false
  var sourceDrops: UInt64 = 0
  var captureDrops: UInt64 = 0
  var poolDrops: UInt64 = 0
  var cameraDrops: UInt64 = 0
  var previewDrops: UInt64 = 0
  var previewFrames: UInt64 = 0
  var outputFPS: Double = 0
  var displayedFrames: UInt64 = 0
  var rendererDrops: UInt64 = 0
  var previewError: String?
  var timecode: String?
  var audioChannels: Int = 0
  var audioSampleRate: Int = 0
  var audioPackets: UInt64 = 0
  var audioSamples: UInt64 = 0
  var audioBytes: UInt64 = 0
  var audioDrops: UInt64 = 0
  var audioPeakLeft: Double = 0
  var audioPeakRight: Double = 0
  var audioRMSLeft: Double = 0
  var audioRMSRight: Double = 0
  var audioBitrateKbps: Double = 0
  var audioPresent = false
  var videoBitrateMbps: Double = 0
  var videoDrops: UInt64 = 0
  var cameraOutputActive = false
  var cameraMessage = "Virtual camera not connected"
  var stopped = false
}

struct CaptureMediaStats: @unchecked Sendable {
  var timecode: String?
  var audioPacketTime: CMTime
  var audioSampleFrames: UInt64
  var audioChannels: Int
  var leftPeak: Double
  var rightPeak: Double
  var leftRMS: Double
  var rightRMS: Double
  var audioBytes: UInt64
  var audioPresent: Bool
}

// All media resources/configuration are queue-owned. Driver admission is bounded
// to twelve retained frames, covering measured source bursts plus queue delay.
// Preview visibility never controls camera processing.
final class CaptureController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.ultrastudiolut.capture", qos: .userInteractive)
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var accepting = false
  private var inFlight = 0
  private var callbackDrops: UInt64 = 0
  private var sourceDrops: UInt64 = 0
  private var sourceDuration = VideoContract.fastDuration
  private var lastSourcePTS: CMTime?
  private var lastReceived: Double = 0
  private let services: CaptureServices
  private let previewRenderers: [VideoPreviewRenderer]
  private let sampleFactory = VideoSampleFactory()
  private var deliveryStager = CameraFrameStager()
  private var processor: LUTProcessor?
  private var configuration = PipelineConfiguration()
  private var pipelineEnabled = true
  private var previewEnabled = true
  private var activeConfiguration: PipelineConfiguration?
  private var activeInputType: OSType?
  private var preparedConfiguration: PipelineConfiguration?
  private var detected: InputFormat?
  private var renderedFormat: InputFormat?
  private var inputLabel = "No signal"
  private var outputLabel = ""
  private var applied: Bool?
  private var frames: UInt64 = 0
  private var cameraDrops: UInt64 = 0
  private var poolDrops: UInt64 = 0
  private var firstSourceTime: CMTime?
  private var lastDeliveredSourceTime: CMTime?
  private var lastDeliveredHostTime: CMTime?
  private var firstHostTime: CMTime = .zero
  private var rateStart: Double = 0
  private var rateFrames: UInt64 = 0
  private var outputFPS: Double = 0
  private var processingMS: Double = 0
  private var timecode: String?
  private var audioChannels = 0
  private var audioSampleRate = 0
  private var audioPackets: UInt64 = 0
  private var audioSamples: UInt64 = 0
  private var audioBytes: UInt64 = 0
  private var audioDrops: UInt64 = 0
  private var audioPeakLeft = 0.0
  private var audioPeakRight = 0.0
  private var audioRMSLeft = 0.0
  private var audioRMSRight = 0.0
  private var audioPresent = false
  private var lastAudioPacketTime: CMTime?
  private var lastAudioSampleFrames: UInt64 = 0
  private var audioRateStart: Double = 0
  private var audioRateBytes: UInt64 = 0
  private var audioBitrateKbps = 0.0
  private var videoRateStart: Double = 0
  private var videoRateBytes: UInt64 = 0
  private var videoBitrateMbps = 0.0
  private var lastPublished: Double = 0
  private var cameraConnected = false
  private var reconnectAttempts = 0
  private var cameraOutage = false
  private var reconnectRequested = false
  private var reconnectAfter: Double = 0
  private var cameraMessage = "Virtual camera not connected"
  private var message = "Stopped"
  private var frameRateGate = FrameRateGate()
  private var watchdog: DispatchSourceTimer?
  private var realtimeActivity: NSObjectProtocol?
  private let logger = Logger(subsystem: "org.ultrastudiolut.app", category: "capture")
  private var lastLogged: Double = 0

  var onUpdate: (@Sendable (CaptureUpdate) -> Void)?

  init(services: CaptureServices = .live(), previewRenderer: VideoPreviewRenderer? = nil,
    additionalPreviewRenderers: [VideoPreviewRenderer] = []) {
    self.services = services
    previewRenderers = (previewRenderer.map { [$0] } ?? []) + additionalPreviewRenderers
  }

  deinit {
    // Every executing controller operation retains self. Final release has
    // exclusive resource access, even if its owner omitted an explicit Stop.
    stopResources()
  }

  func load(_ cube: CubeLUT, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      do {
        if self.processor == nil { self.processor = try LUTProcessor() }
        try self.processor!.load(cube)
        if self.pipelineEnabled && self.configuration.applyLUT {
          self.previewRenderers.forEach { $0.flush() }
        }
        DispatchQueue.main.async { completion(.success(())) }
      } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }
  }

  func start(deviceID: String, configuration: PipelineConfiguration,
    pipelineEnabled: Bool = true, previewEnabled: Bool = true) {
    let token = lock.withLock {
      generation &+= 1
      accepting = false
      return generation
    }
    queue.async { [self] in
      guard self.isCurrent(token) else { return }
      self.stopResources()
      do {
        if self.processor == nil { self.processor = try LUTProcessor() }
        self.realtimeActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .latencyCritical], reason: "Live UltraStudio video processing")
        self.configuration = configuration
        self.pipelineEnabled = pipelineEnabled
        self.previewEnabled = previewEnabled
        self.activeConfiguration = nil
        self.activeInputType = nil
        self.detected = nil
        self.inputLabel = "Waiting for detected input"
        self.outputLabel = ""
        self.applied = nil
        self.frames = 0
        self.cameraDrops = 0
        self.poolDrops = 0
        self.firstSourceTime = nil
        self.lastDeliveredSourceTime = nil
        self.lastDeliveredHostTime = nil
        self.rateStart = 0
        self.rateFrames = 0
        self.outputFPS = 0
        self.processingMS = 0
        self.timecode = nil
        self.audioChannels = 0
        self.audioSampleRate = 0
        self.audioPackets = 0
        self.audioSamples = 0
        self.audioBytes = 0
        self.audioDrops = 0
        self.audioPeakLeft = 0
        self.audioPeakRight = 0
        self.audioRMSLeft = 0
        self.audioRMSRight = 0
        self.audioPresent = false
        self.lastAudioPacketTime = nil
        self.lastAudioSampleFrames = 0
        self.audioRateStart = 0
        self.audioRateBytes = 0
        self.audioBitrateKbps = 0
        self.videoRateStart = 0
        self.videoRateBytes = 0
        self.videoBitrateMbps = 0
        self.lastPublished = 0
        self.lastLogged = 0
        self.frameRateGate = FrameRateGate()
        self.sampleFactory.reset()
        self.cameraConnected = false
        self.cameraMessage = "Waiting for detected input"
        // Connect and warm before enabling driver callbacks. Cold CMIO/GPU
        // setup on the first frame can otherwise overflow the admission FIFO.
        // The remembered rate is provisional: the first validated frame still
        // establishes the exact contract, and only received data sets metadata.
        let warm = self.effectiveConfiguration(inputFast: configuration.inputFast)
        if let type = self.services.capturePixelFormat {
          try self.establish(warm, inputType: type)
        } else if self.services.startAutomatic == nil {
          try self.establish(warm, inputType: kCVPixelFormatType_422YpCbCr10)
        }
        guard self.isCurrent(token) else { self.stopResources(); return }
        let hasPreview = previewEnabled &&
          (self.previewRenderers.contains { $0.isVisible } || self.services.preview != nil)
        if self.cameraConnected || hasPreview {
          try self.ensurePrepared(warm)
          if warm.untouched, let type = self.services.capturePixelFormat {
            try self.deliveryStager.prepare(width: 3840, height: 2160, pixelFormat: type)
          }
        }
        guard self.isCurrent(token) else { self.stopResources(); return }
        self.lock.withLock {
          self.accepting = true
          self.callbackDrops = 0
          self.sourceDrops = 0
          self.lastSourcePTS = nil
          self.sourceDuration = configuration.inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          self.lastReceived = ProcessInfo.processInfo.systemUptime
        }
        let event: (String) -> Void = { [weak self] value in
          guard let self else { return }
          self.queue.async {
            guard self.isAccepting(token) else { return }
            if value.hasPrefix("Capture error: ") {
              self.fail(value, token: token)
              return
            }
            self.message = value
            if value.localizedCaseInsensitiveContains("no video signal") ||
              value.localizedCaseInsensitiveContains("no HDMI video signal") ||
              value.localizedCaseInsensitiveContains("unsupported") {
              self.clearSignal()
              self.inputLabel = value
            }
            self.publishCurrent(token: token)
          }
        }
        let media: (CaptureMediaStats) -> Void = { [weak self] stats in
            guard let self else { return }
            self.receiveMedia(stats, token: token)
          }
        if let automatic = self.services.startAutomatic {
          if let automaticWithMedia = self.services.startAutomaticWithMedia {
            try automaticWithMedia(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, media, event)
          } else {
            try automatic(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, event)
          }
        } else if let startWithMedia = self.services.startWithMedia {
          try startWithMedia(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, media, event)
        } else {
          try self.services.start(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, event)
        }
        guard self.isCurrent(token) else { self.stopResources(); return }
        self.message = "Waiting for UltraStudio signal…"
        self.publishCurrent(token: token)
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
          guard let self, self.isAccepting(token) else { return }
          let last = self.lock.withLock { self.lastReceived }
          if ProcessInfo.processInfo.systemUptime - last > 2 {
            if self.services.startAutomatic != nil {
              if self.detected != nil || self.message == "Waiting for UltraStudio signal…" {
                self.clearSignal()
                self.message = "No video signal — waiting for HDMI."
                self.publishCurrent(token: token)
              }
            } else {
              self.fail("No valid video signal for two seconds. Check the FX3 HDMI output.", token: token)
            }
          }
        }
        self.watchdog = timer
        timer.resume()
      } catch { self.fail(error.localizedDescription, token: token) }
    }
  }

  func reconfigure(configuration: PipelineConfiguration, pipelineEnabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      self.configuration = configuration
      self.pipelineEnabled = pipelineEnabled
      if !self.cameraConnected { self.reconnectRequested = true }
      self.applied = nil
      self.outputLabel = ""
      self.sampleFactory.reset()
      self.previewRenderers.forEach { $0.flush() }
      self.message = self.detected == nil ? "Waiting for UltraStudio signal…" : "Updating output…"
      self.publishCurrent(token: token)
      // First new frame establishes the exact source-dependent output contract.
    }
  }

  func setPreviewEnabled(_ enabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      self.previewEnabled = enabled
      if !enabled { self.previewRenderers.forEach { $0.flush() } }
      self.publishCurrent(token: token)
    }
  }

  func stop() {
    let token = lock.withLock {
      generation &+= 1
      accepting = false
      return generation
    }
    queue.async {
      guard self.isCurrent(token) else { return }
      self.stopResources()
      self.detected = nil
      self.inputLabel = "No signal"
      self.outputLabel = ""
      self.applied = nil
      self.message = "Stopped"
      self.publishCurrent(token: token, stopped: true)
    }
  }

  private func isCurrent(_ token: UInt64) -> Bool { lock.withLock { generation == token } }
  private func isAccepting(_ token: UInt64) -> Bool { lock.withLock { generation == token && accepting } }

  private func stopResources() {
    watchdog?.cancel()
    watchdog = nil
    if let activity = realtimeActivity { ProcessInfo.processInfo.endActivity(activity) }
    realtimeActivity = nil
    previewRenderers.forEach { $0.flush() }
    services.stop()
    services.disconnect()
    cameraConnected = false
    reconnectAttempts = 0
    cameraOutage = false
    reconnectRequested = false
    reconnectAfter = 0
    cameraMessage = "Virtual camera not connected"
    activeConfiguration = nil
    activeInputType = nil
    deliveryStager = CameraFrameStager()
    processor?.releaseIdleResources()
    preparedConfiguration = nil
  }

  private func clearSignal() {
    lock.withLock { lastSourcePTS = nil }
    detected = nil
    inputLabel = "No signal"
    outputLabel = ""
    applied = nil
    outputFPS = 0
    firstSourceTime = nil
    frameRateGate = FrameRateGate()
    previewRenderers.forEach { $0.flush() }
  }

  private func fail(_ value: String, token: UInt64) {
    guard isCurrent(token) else { return }
    lock.withLock { accepting = false }
    stopResources()
    applied = nil
    outputLabel = ""
    message = value
    logger.error("Capture stopped: \(value, privacy: .public)")
    publishCurrent(token: token, stopped: true)
  }

  private func effectiveConfiguration(inputFast: Bool) -> PipelineConfiguration {
    var result = pipelineEnabled ? configuration : PipelineConfiguration(
      applyLUT: false, downscale: false, convertTo420: false, reduceFrameRate: false)
    result.inputFast = inputFast
    return result
  }

  private func ensurePrepared(_ next: PipelineConfiguration) throws {
    if preparedConfiguration?.applyLUT != next.applyLUT || preparedConfiguration?.downscale != next.downscale ||
      preparedConfiguration?.convertTo420 != next.convertTo420 {
      try processor?.prepare(configuration: next)
      preparedConfiguration = next
    }
  }

  private func establish(_ next: PipelineConfiguration, inputType: OSType) throws {
    let prior = activeConfiguration
    let sameContract = prior.map {
      $0.width == next.width && $0.height == next.height &&
        $0.pixelFormat == next.pixelFormat && $0.duration == next.duration &&
        $0.untouched == next.untouched && activeInputType == inputType
    } ?? false
    let now = ProcessInfo.processInfo.systemUptime
    if sameContract {
      activeConfiguration = next
      guard !cameraConnected, (reconnectRequested || reconnectAttempts > 0), now >= reconnectAfter else { return }
      if reconnectAttempts > 0 { reconnectAttempts -= 1 }
    }
    let wasConnected = cameraConnected
    services.disconnect()
    cameraConnected = false
    reconnectRequested = false
    reconnectAfter = now + max(0, services.cameraRetryInterval)
    // A retry of the same contract must preserve prepared transport resources
    // and the existing source cadence used by the surviving local preview.
    if prior != nil && !sameContract { deliveryStager = CameraFrameStager() }
    do {
      try services.connect(next, inputType)
      cameraConnected = true
      cameraMessage = "Virtual camera connected — choose UltraStudio LUT in Zoom"
    } catch {
      cameraMessage = "Camera output unavailable — \(error.localizedDescription)"
      if wasConnected { beginCameraRecovery() }
    }
    activeConfiguration = next
    activeInputType = inputType
    if prior?.duration != next.duration { frameRateGate = FrameRateGate() }
    if !sameContract { sampleFactory.reset() }
  }

  private func beginCameraRecovery() {
    guard !cameraOutage else { return }
    cameraOutage = true
    reconnectAttempts = 3
  }

  private func receive(_ image: CVPixelBuffer, at pts: CMTime, duration: CMTime?,
    signalValid: Bool, token: UInt64) {
    guard signalValid else { return }
    let accepted = lock.withLock { () -> CMTime? in
      guard generation == token, accepting else { return nil }
      let frameDuration = duration ?? sourceDuration
      lastReceived = ProcessInfo.processInfo.systemUptime
      if frameDuration.isNumeric, frameDuration.seconds > 0, frameDuration != sourceDuration {
        sourceDuration = frameDuration
        lastSourcePTS = nil
      }
      if pts.isNumeric {
        if let prior = lastSourcePTS, sourceDuration.isNumeric, sourceDuration.seconds > 0 {
          let intervals = CMTimeSubtract(pts, prior).seconds / sourceDuration.seconds
          if intervals > 1.5, intervals < 600 { sourceDrops &+= UInt64(intervals.rounded() - 1) }
        }
        lastSourcePTS = pts
      }
      if inFlight >= VideoContract.captureAdmissionLimit { callbackDrops &+= 1; return nil }
      inFlight += 1
      return frameDuration
    }
    guard let accepted else { return }
    let frame = CapturedFrame(image: image, pts: pts, duration: accepted,
      receivedAt: ProcessInfo.processInfo.systemUptime)
    queue.async {
      defer { self.lock.withLock { self.inFlight -= 1 } }
      guard self.isAccepting(token) else { return }
      self.process(frame, token: token)
    }
  }

  private func receiveMedia(_ stats: CaptureMediaStats, token: UInt64) {
    queue.async {
      guard self.isAccepting(token) else { return }
      self.recordMedia(stats)
    }
  }

  private func recordMedia(_ stats: CaptureMediaStats) {
    timecode = stats.timecode
    audioChannels = max(0, stats.audioChannels)
    audioPackets &+= 1
    audioSamples &+= stats.audioSampleFrames
    audioBytes &+= stats.audioBytes
    audioRateBytes &+= stats.audioBytes
    audioPresent = stats.audioPresent
    audioPeakLeft = max(0, min(1, stats.leftPeak))
    audioPeakRight = max(0, min(1, stats.rightPeak))
    audioRMSLeft = max(0, min(1, stats.leftRMS))
    audioRMSRight = max(0, min(1, stats.rightRMS))
    // The DeckLink packet has no explicit sample-rate field. Infer it from
    // contiguous packet timestamps and use it to account for missing samples.
    if let prior = lastAudioPacketTime, stats.audioPacketTime.isNumeric,
      prior.isNumeric, stats.audioSampleFrames > 0 {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(stats.audioPacketTime, prior))
      if elapsed > 0 {
        let inferred = Double(lastAudioSampleFrames) / elapsed
        if inferred >= 1_000, inferred <= 384_000 {
          if audioSampleRate == 0 { audioSampleRate = Int(inferred.rounded()) }
          if audioSampleRate > 0 {
            let expected = Int((elapsed * Double(audioSampleRate)).rounded())
            if expected > Int(lastAudioSampleFrames) {
              audioDrops &+= UInt64(expected - Int(lastAudioSampleFrames))
            }
          }
        }
      }
    }
    if stats.audioPacketTime.isNumeric { lastAudioPacketTime = stats.audioPacketTime }
    lastAudioSampleFrames = stats.audioSampleFrames
  }

  private func process(_ frame: CapturedFrame, token: UInt64) {
    let input = frame.image
    videoRateBytes &+= UInt64(max(0, CVPixelBufferGetDataSize(input)))
    let actual = InputFormat(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input),
      type: CVPixelBufferGetPixelFormatType(input), duration: frame.duration)
    var metadataChanged = detected != actual
    if detected != actual {
      if detected != nil { previewRenderers.forEach { $0.flush() } }
      if detected?.duration != actual.duration { firstSourceTime = nil; frameRateGate = FrameRateGate() }
      detected = actual
      inputLabel = actual.label
    }
    guard actual.width == 3840, actual.height == 2160, VideoContract.tenBit422.contains(actual.type) else {
      fail("Unsupported detected input: \(actual.label). Expected 4K 10-bit 4:2:2.", token: token)
      return
    }
    guard frame.pts.isNumeric, frame.pts.epoch == 0, actual.duration.epoch == 0, let processor,
      actual.duration == VideoContract.fastDuration || actual.duration == VideoContract.slowDuration else {
      fail("Unsupported or invalid detected frame timing.", token: token)
      return
    }
    do {
      try VideoBufferLayout.validate(input)
      let effective = effectiveConfiguration(inputFast: actual.duration == VideoContract.fastDuration)
      try establish(effective, inputType: actual.type)
      guard isAccepting(token) else { return }
      let visible = previewEnabled ? previewRenderers.filter { $0.isVisible } : []
      let hasPreview = previewEnabled && (!visible.isEmpty || services.preview != nil)
      // No downstream demand: keep metadata/detection alive without allocating,
      // submitting GPU work or staging raw buffers that nobody can consume.
      guard cameraConnected || hasPreview else {
        if preparedConfiguration != nil {
          processor.releaseIdleResources()
          preparedConfiguration = nil
          deliveryStager = CameraFrameStager()
        }
        applied = nil
        outputLabel = ""
        processingMS = 0
        outputFPS = 0
        message = "Feed ready — no active video destination."
        publishIfDue(token: token, force: metadataChanged)
        return
      }
      try ensurePrepared(effective)
      let start = ProcessInfo.processInfo.systemUptime
      let rendered = effective.untouched ? input : try processor.process(input, configuration: effective)
      processingMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
      services.didProcess(processingMS, (start - frame.receivedAt) * 1000)
      guard isAccepting(token) else { return }
      // Temporal selection remains last; bypass retains the source duration.
      guard frameRateGate.shouldDeliver(frame.pts, duration: effective.duration) else { return }
      let time = hostTime(for: frame.pts, duration: effective.duration)
      let original = try sampleFactory.sample(rendered, at: time, duration: effective.duration)
      let sample: CMSampleBuffer
      if effective.untouched && (cameraConnected || !visible.isEmpty) {
        if CVPixelBufferGetIOSurface(rendered) == nil {
          try deliveryStager.prepare(width: actual.width, height: actual.height, pixelFormat: actual.type)
        }
        guard isAccepting(token) else { return }
        guard let shared = try deliveryStager.stage(original) else { poolDrops &+= 1; return }
        sample = shared
      } else { sample = original }
      guard isAccepting(token) else { return }
      if previewEnabled {
        visible.forEach { $0.enqueue(sample) }
        services.preview?(sample)
      }
      if cameraConnected {
        do {
          if try services.send(sample) {
            // An opened queue is not proof of recovery. Only a successful
            // frame send ends the outage and permits a fresh retry budget.
            cameraOutage = false
            reconnectAttempts = 0
          } else { cameraDrops &+= 1 }
        }
        catch {
          cameraDrops &+= 1
          services.disconnect()
          cameraConnected = false
          beginCameraRecovery()
          reconnectRequested = false
          reconnectAfter = ProcessInfo.processInfo.systemUptime + max(0, services.cameraRetryInterval)
          cameraMessage = "Camera output disconnected — \(error.localizedDescription)"
        }
      }
      frames &+= 1
      lastDeliveredSourceTime = frame.pts
      lastDeliveredHostTime = time
      metadataChanged = metadataChanged || applied != pipelineEnabled
      applied = pipelineEnabled
      let output = InputFormat(width: CVPixelBufferGetWidth(rendered), height: CVPixelBufferGetHeight(rendered),
        type: CVPixelBufferGetPixelFormatType(rendered), duration: effective.duration)
      if renderedFormat != output || outputLabel.isEmpty {
        metadataChanged = true
        renderedFormat = output
        outputLabel = output.label
      }
      message = pipelineEnabled ? (effective.applyLUT ? "Processing enabled — LUT applied" : "Processing enabled — LUT off") : "Complete bypass — original feed"
      publishIfDue(token: token, force: frames == 1 || metadataChanged)
    } catch VideoError.outputBackPressure { poolDrops &+= 1 }
    catch { fail(error.localizedDescription, token: token) }
  }

  private func hostTime(for sourceTime: CMTime, duration: CMTime) -> CMTime {
    let now = services.hostTime()
    var reset = firstSourceTime == nil
    if let last = lastDeliveredSourceTime, CMTimeCompare(sourceTime, last) < 0 { reset = true }
    if let origin = firstSourceTime {
      let mapped = CMTimeAdd(firstHostTime, CMTimeSubtract(sourceTime, origin))
      // Preserve normal source cadence independently of GPU completion jitter.
      // A discontinuous source clock must not schedule output seconds into the
      // future. Late processing alone must preserve source cadence, including
      // a costly hot change that temporarily puts its first frame behind now.
      if CMTimeSubtract(mapped, now).seconds > 0.5 { reset = true }
    }
    if reset {
      firstSourceTime = sourceTime
      firstHostTime = now
      if let last = lastDeliveredHostTime {
        firstHostTime = CMTimeMaximum(firstHostTime, CMTimeAdd(last, duration))
      }
    }
    return CMTimeAdd(firstHostTime, CMTimeSubtract(sourceTime, firstSourceTime!))
  }

  private func publishIfDue(token: UInt64, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastPublished >= 0.25 else { return }
    let elapsed = now - rateStart
    outputFPS = rateStart == 0 ? 0 : Double(frames - rateFrames) / elapsed
    rateStart = now
    rateFrames = frames
    if audioRateStart == 0 { audioRateStart = now }
    if videoRateStart == 0 { videoRateStart = now }
    let mediaElapsed = now - audioRateStart
    if mediaElapsed >= 0.25 {
      audioBitrateKbps = Double(audioRateBytes) * 8 / mediaElapsed / 1_000
      audioRateBytes = 0
      audioRateStart = now
      let videoElapsed = max(0.001, now - videoRateStart)
      videoBitrateMbps = Double(videoRateBytes) * 8 / videoElapsed / 1_000_000
      videoRateBytes = 0
      videoRateStart = now
    }
    lastPublished = now
    previewRenderers.filter { previewEnabled && $0.isVisible }.forEach { $0.refreshPerformanceMetrics() }
    if now - lastLogged >= 5 {
      lastLogged = now
      if let packed = processor?.packedInputDiagnostics {
        logger.notice("Packed input noCopy=\(packed.noCopyFrames) copiedFallback=\(packed.copiedFrames)")
      }
      let losses = lock.withLock { (sourceDrops, callbackDrops) }
      logger.notice("Live fps=\(self.outputFPS) delivered=\(self.frames) sourceDrops=\(losses.0) captureDrops=\(losses.1) poolDrops=\(self.poolDrops)")
    }
    publishCurrent(token: token)
  }

  private func publishCurrent(token: UInt64, stopped: Bool = false) {
    let losses = lock.withLock { (sourceDrops, callbackDrops) }
    let diagnostics = previewRenderers.map { $0.diagnosticsSnapshot() }
    let previewLosses = diagnostics.reduce(UInt64(0)) {
      $0 + $1.stagingDrops + $1.replaced + $1.failed + $1.rendererDropped + $1.rendererCorrupted
    }
    let visiblePreview = previewEnabled && (previewRenderers.contains { $0.isVisible } || services.preview != nil)
    let update = CaptureUpdate(message: message, input: inputLabel, output: outputLabel,
      inputFast: detected.map { $0.duration == VideoContract.fastDuration }, sourceDuration: detected?.duration,
      pipelineEnabledApplied: applied, frames: frames, dropped: losses.0 + losses.1 + poolDrops + cameraDrops,
      processingMS: processingMS, previewDelivered: visiblePreview && !outputLabel.isEmpty && !stopped,
      sourceDrops: losses.0, captureDrops: losses.1, poolDrops: poolDrops, cameraDrops: cameraDrops,
      previewDrops: previewLosses, previewFrames: diagnostics.reduce(0) { $0 + $1.enqueued },
      outputFPS: outputFPS, displayedFrames: diagnostics.reduce(0) { $0 + $1.rendererFrames },
      rendererDrops: diagnostics.reduce(0) { $0 + $1.rendererDropped },
      previewError: diagnostics.compactMap(\.lastError).first,
      timecode: stopped ? nil : timecode,
      audioChannels: stopped ? 0 : audioChannels, audioSampleRate: stopped ? 0 : audioSampleRate,
      audioPackets: stopped ? 0 : audioPackets, audioSamples: stopped ? 0 : audioSamples,
      audioBytes: stopped ? 0 : audioBytes, audioDrops: stopped ? 0 : audioDrops,
      audioPeakLeft: stopped ? 0 : audioPeakLeft, audioPeakRight: stopped ? 0 : audioPeakRight,
      audioRMSLeft: stopped ? 0 : audioRMSLeft, audioRMSRight: stopped ? 0 : audioRMSRight,
      audioBitrateKbps: stopped ? 0 : audioBitrateKbps, audioPresent: stopped ? false : audioPresent,
      videoBitrateMbps: stopped ? 0 : videoBitrateMbps,
      videoDrops: stopped ? 0 : losses.0 + losses.1 + poolDrops + cameraDrops,
      cameraOutputActive: cameraConnected, cameraMessage: cameraMessage, stopped: stopped)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrent(token) else { return }
      self.onUpdate?(update)
    }
  }
}

private struct CapturedFrame: @unchecked Sendable {
  let image: CVPixelBuffer
  let pts: CMTime
  let duration: CMTime
  let receivedAt: Double
}

private struct InputFormat: Equatable {
  let width: Int
  let height: Int
  let type: OSType
  let duration: CMTime

  var label: String {
    let color: String
    switch type {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: color = "4:2:0 8-bit"
    case kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: color = "4:2:2 10-bit"
    default: color = "Unknown color format"
    }
    let rate = duration.isNumeric && duration.seconds > 0 ? String(format: "%.2f fps", 1 / duration.seconds) : "Rate unknown"
    return "\(width) × \(height) · \(VideoContract.fourCC(type)) · \(color) · \(rate)"
  }
}

struct CaptureServices: @unchecked Sendable {
  var start: (String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void
  var startWithMedia: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var stop: () -> Void
  var connect: (PipelineConfiguration, OSType) throws -> Void
  var disconnect: () -> Void
  var send: (CMSampleBuffer) throws -> Bool
  var preview: ((CMSampleBuffer) -> Void)?
  var didProcess: (Double, Double) -> Void = { _, _ in }
  var startAutomatic: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithMedia: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  // Known backend storage layout is used only to prepare transport memory;
  // displayed input metadata always comes from received buffers and duration.
  var capturePixelFormat: OSType?
  var hostTime: () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
  var cameraRetryInterval: TimeInterval = 2

  static func live() -> CaptureServices {
    let backend = UDLBackend()
    let sink = CameraSink()
    return CaptureServices(
      start: { id, fast, frame, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame, eventHandler: event)
      },
      startWithMedia: { id, fast, frame, media, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, eventHandler: event)
      },
      stop: { backend.stop() },
      connect: { config, format in try sink.connect(configuration: config, passthroughFormat: format) },
      disconnect: { sink.disconnect() },
      send: { try sink.send($0) },
      startAutomatic: { id, frame, event in
        try backend.startAuto(deviceID: id, frameHandler: frame, eventHandler: event)
      },
      startAutomaticWithMedia: { id, frame, media, event in
        try backend.startAuto(deviceID: id, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, eventHandler: event)
      }, capturePixelFormat: kCVPixelFormatType_422YpCbCr10)
  }
}

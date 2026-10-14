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
  var cameraOutputActive = false
  var cameraMessage = "Virtual camera not connected"
  var stopped = false
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
  private var lastPublished: Double = 0
  private var cameraConnected = false
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
        self.lastPublished = 0
        self.lastLogged = 0
        self.frameRateGate = FrameRateGate()
        self.sampleFactory.reset()
        self.cameraConnected = false
        self.cameraMessage = "Waiting for detected input"
        // Warm pixel resources before enabling native capture. Input duration
        // is still unknown; automatic capture negotiates output on its first frame.
        let warm = self.effectiveConfiguration(inputFast: configuration.inputFast)
        if previewEnabled && (self.previewRenderers.contains { $0.isVisible } || self.services.preview != nil) {
          try self.ensurePrepared(warm)
          if warm.untouched, let type = self.services.capturePixelFormat {
            try self.deliveryStager.prepare(width: 3840, height: 2160, pixelFormat: type)
          }
        }
        if self.services.startAutomatic == nil {
          try self.establish(warm, inputType: kCVPixelFormatType_422YpCbCr10)
          if self.cameraConnected { try self.ensurePrepared(warm) }
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
        if let automatic = self.services.startAutomatic {
          try automatic(deviceID, { [weak self] image, pts, duration, valid in
            self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
          }, event)
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
      guard self.isCurrent(token) else { return }
      self.configuration = configuration
      self.pipelineEnabled = pipelineEnabled
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
      guard self.isCurrent(token) else { return }
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
    if let prior, prior.width == next.width, prior.height == next.height,
      prior.pixelFormat == next.pixelFormat, prior.duration == next.duration,
      prior.untouched == next.untouched, activeInputType == inputType {
      activeConfiguration = next
      return
    }
    services.disconnect()
    cameraConnected = false
    if prior != nil { deliveryStager = CameraFrameStager() }
    do {
      try services.connect(next, inputType)
      cameraConnected = true
      cameraMessage = "Virtual camera connected — choose UltraStudio LUT in Zoom"
    } catch { cameraMessage = "Camera output unavailable — \(error.localizedDescription)" }
    activeConfiguration = next
    activeInputType = inputType
    if prior?.duration != next.duration { frameRateGate = FrameRateGate() }
    sampleFactory.reset()
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

  private func process(_ frame: CapturedFrame, token: UInt64) {
    let input = frame.image
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
      if let last = lastDeliveredSourceTime, CMTimeCompare(frame.pts, last) < 0 { firstSourceTime = nil }
      if firstSourceTime == nil || CMTimeCompare(frame.pts, firstSourceTime!) < 0 {
        firstSourceTime = frame.pts
        firstHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastDeliveredHostTime {
          firstHostTime = CMTimeMaximum(firstHostTime, CMTimeAdd(last, effective.duration))
        }
      }
      let time = CMTimeAdd(firstHostTime, CMTimeSubtract(frame.pts, firstSourceTime!))
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
        do { if !(try services.send(sample)) { cameraDrops &+= 1 } }
        catch {
          services.disconnect()
          cameraConnected = false
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

  private func publishIfDue(token: UInt64, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastPublished >= 0.25 else { return }
    let elapsed = now - rateStart
    outputFPS = rateStart == 0 ? 0 : Double(frames - rateFrames) / elapsed
    rateStart = now
    rateFrames = frames
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
  var stop: () -> Void
  var connect: (PipelineConfiguration, OSType) throws -> Void
  var disconnect: () -> Void
  var send: (CMSampleBuffer) throws -> Bool
  var preview: ((CMSampleBuffer) -> Void)?
  var didProcess: (Double, Double) -> Void = { _, _ in }
  var startAutomatic: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void)?
  // Known backend storage layout is used only to prepare transport memory;
  // displayed input metadata always comes from received buffers and duration.
  var capturePixelFormat: OSType?

  static func live() -> CaptureServices {
    let backend = UDLBackend()
    let sink = CameraSink()
    return CaptureServices(
      start: { id, fast, frame, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame, eventHandler: event)
      },
      stop: { backend.stop() },
      connect: { config, format in try sink.connect(configuration: config, passthroughFormat: format) },
      disconnect: { sink.disconnect() },
      send: { try sink.send($0) },
      startAutomatic: { id, frame, event in
        try backend.startAuto(deviceID: id, frameHandler: frame, eventHandler: event)
      }, capturePixelFormat: kCVPixelFormatType_422YpCbCr10)
  }
}

import CoreVideo
import CoreMedia
import Foundation
import os

struct CaptureUpdate: @unchecked Sendable {
  var message: String
  var input: String = "No signal"
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

// Configuration, processing and stop resources are serial. Driver callbacks
// only take a short lock; six retained frames absorb measured five-frame
// callback bursts without allowing an unbounded queue.
final class CaptureController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.ultrastudiolut.capture", qos: .userInteractive)
  private let stateLock = NSLock()
  private var generation: UInt64 = 0
  private var accepting = false
  private var inFlight = 0
  private var callbackDrops: UInt64 = 0
  private var sourceDrops: UInt64 = 0
  private var sourceDuration = VideoContract.fastDuration
  private var lastSourcePTS: CMTime?
  private var lastReceived: Double = 0
  private let services: CaptureServices
  private let previewRenderer: VideoPreviewRenderer?
  private let sampleFactory = VideoSampleFactory()
  private let deliveryStager = CameraFrameStager()
  private var processor: LUTProcessor?
  private var configuration = PipelineConfiguration()
  private var frames: UInt64 = 0
  private var cameraDrops: UInt64 = 0
  private var poolDrops: UInt64 = 0
  private var firstSourceTime: CMTime?
  private var firstHostTime: CMTime = .zero
  private var rateStart: Double = 0
  private var rateFrames: UInt64 = 0
  private var lastPublished: Double = 0
  private var cameraConnected = false
  private var cameraMessage = "Virtual camera not connected"
  private var frameRateGate = FrameRateGate()
  private var watchdog: DispatchSourceTimer?
  private var realtimeActivity: NSObjectProtocol?
  private let logger = Logger(subsystem: "org.ultrastudiolut.app", category: "capture")
  private var lastLogged: Double = 0
  var onUpdate: (@Sendable (CaptureUpdate) -> Void)?

  init(services: CaptureServices = .live(), previewRenderer: VideoPreviewRenderer? = nil) {
    self.services = services
    self.previewRenderer = previewRenderer
  }

  func load(_ cube: CubeLUT, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      do {
        if self.processor == nil { self.processor = try LUTProcessor() }
        try self.processor!.load(cube)
        DispatchQueue.main.async { completion(.success(())) }
      } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }
  }

  func start(deviceID: String, configuration: PipelineConfiguration) {
    let token = stateLock.withLock {
      generation &+= 1
      accepting = false
      return generation
    }
    queue.async {
      guard self.isCurrent(token) else { return }
      self.stopResources()
      do {
        if self.processor == nil { self.processor = try LUTProcessor() }
        self.realtimeActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .latencyCritical], reason: "Live UltraStudio video processing")
        self.configuration = configuration
        self.frames = 0
        self.cameraDrops = 0
        self.poolDrops = 0
        self.firstSourceTime = nil
        self.rateStart = 0
        self.rateFrames = 0
        try self.processor!.prepare(configuration: configuration)
        self.lastPublished = 0
        self.lastLogged = 0
        self.frameRateGate = FrameRateGate()
        self.sampleFactory.reset()
        self.cameraConnected = false
        do {
          try self.services.connect(configuration, kCVPixelFormatType_422YpCbCr10)
          self.cameraConnected = true
          self.cameraMessage = "Virtual camera connected — choose UltraStudio LUT in Zoom"
        } catch {
          self.cameraMessage = "Preview only — \(error.localizedDescription)"
        }
        guard self.isCurrent(token) else { self.stopResources(); return }
        self.stateLock.withLock {
          self.accepting = true
          self.callbackDrops = 0
          self.sourceDrops = 0
          self.lastSourcePTS = nil
          self.sourceDuration = configuration.inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          self.lastReceived = ProcessInfo.processInfo.systemUptime
        }
        try self.services.start(deviceID, configuration.inputFast,
          { [weak controller = self] image, pts, signalValid in
            controller?.receive(image, at: pts, signalValid: signalValid, token: token)
          }, { [weak controller = self] message in
            guard let self = controller else { return }
            self.queue.async {
              guard self.isAccepting(token) else { return }
              self.publish(CaptureUpdate(message: message, cameraOutputActive: self.cameraConnected,
                cameraMessage: self.cameraMessage), token: token)
            }
          })
        guard self.isCurrent(token) else { self.stopResources(); return }
        self.publish(CaptureUpdate(message: "Waiting for 4K 10-bit UltraStudio signal…",
          cameraOutputActive: self.cameraConnected, cameraMessage: self.cameraMessage), token: token)
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak controller = self] in
          guard let self = controller, self.isCurrent(token) else { return }
          let last = self.stateLock.withLock { self.lastReceived }
          if ProcessInfo.processInfo.systemUptime - last > 2 {
            self.fail("No valid video signal for two seconds. Check the FX3 HDMI output and selected frame rate.", token: token)
          }
        }
        self.watchdog = timer
        timer.resume()
      } catch { self.fail(error.localizedDescription, token: token) }
    }
  }

  func stop() {
    let token = stateLock.withLock {
      generation &+= 1
      accepting = false
      return generation
    }
    queue.async {
      guard self.isCurrent(token) else { return }
      self.stopResources()
      self.publish(CaptureUpdate(message: "Stopped", stopped: true), token: token)
    }
  }

  private func isCurrent(_ token: UInt64) -> Bool { stateLock.withLock { generation == token } }
  private func isAccepting(_ token: UInt64) -> Bool { stateLock.withLock { generation == token && accepting } }

  private func stopResources() {
    watchdog?.cancel()
    watchdog = nil
    if let activity = realtimeActivity { ProcessInfo.processInfo.endActivity(activity) }
    realtimeActivity = nil
    previewRenderer?.flush()
    services.stop()
    services.disconnect()
    cameraConnected = false
  }

  private func fail(_ message: String, token: UInt64) {
    guard isCurrent(token) else { return }
    stateLock.withLock { accepting = false }
    stopResources()
    logger.error("Capture stopped: \(message, privacy: .public)")
    publish(CaptureUpdate(message: message, cameraMessage: cameraMessage, stopped: true), token: token)
  }

  private func publish(_ update: CaptureUpdate, token: UInt64) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrent(token) else { return }
      self.onUpdate?(update)
    }
  }

  private func receive(_ image: CVPixelBuffer, at pts: CMTime, signalValid: Bool, token: UInt64) {
    guard signalValid else { return }
    let accepted = stateLock.withLock {
      guard generation == token, accepting else { return false }
      lastReceived = ProcessInfo.processInfo.systemUptime
      if pts.isNumeric {
        if let previous = lastSourcePTS {
          let intervals = CMTimeSubtract(pts, previous).seconds / sourceDuration.seconds
          if intervals > 1.5, intervals < 600 { sourceDrops &+= UInt64(intervals.rounded() - 1) }
        }
        lastSourcePTS = pts
      }
      if inFlight >= 6 { callbackDrops &+= 1; return false }
      inFlight += 1
      return true
    }
    guard accepted else { return }
    let frame = CapturedFrame(image: image, pts: pts, receivedAt: ProcessInfo.processInfo.systemUptime)
    queue.async {
      defer { self.stateLock.withLock { self.inFlight -= 1 } }
      guard self.isAccepting(token) else { return }
      self.process(frame, token: token)
    }
  }

  private func process(_ frame: CapturedFrame, token: UInt64) {
    let input = frame.image
    guard CVPixelBufferGetWidth(input) == 3840, CVPixelBufferGetHeight(input) == 2160,
      VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(input)) else {
      fail("Input changed from 4K 10-bit 4:2:2. Capture stopped to preserve source precision.", token: token)
      return
    }
    guard frame.pts.isValid, frame.pts.isNumeric, let processor else {
      fail("Camera supplied an invalid frame timestamp.", token: token)
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    do {
      let rendered = try processor.process(input, configuration: configuration)
      services.didProcess((ProcessInfo.processInfo.systemUptime - now) * 1000, (now - frame.receivedAt) * 1000)
      guard isAccepting(token) else { return }
      // Temporal reduction is last, after full-precision pixel processing.
      guard frameRateGate.shouldDeliver(frame.pts, duration: configuration.duration) else { return }
      if firstSourceTime == nil || CMTimeCompare(frame.pts, firstSourceTime!) < 0 {
        firstSourceTime = frame.pts
        firstHostTime = CMClockGetTime(CMClockGetHostTimeClock())
      }
      let outputTime = CMTimeAdd(firstHostTime, CMTimeSubtract(frame.pts, firstSourceTime!))
      let original = try sampleFactory.sample(rendered, at: outputTime, duration: configuration.duration)
      // Share raw staging once between preview and CMIO. Processed Metal
      // buffers are already IOSurfaces and pass through without another copy.
      let sample: CMSampleBuffer
      if configuration.untouched && (previewRenderer != nil || cameraConnected) {
        guard let staged = try deliveryStager.stage(original) else { poolDrops &+= 1; return }
        sample = staged
      } else { sample = original }
      previewRenderer?.enqueue(sample)
      services.preview(sample)
      if cameraConnected {
        do {
          if !(try services.send(sample)) { cameraDrops &+= 1 }
        } catch {
          services.disconnect()
          cameraConnected = false
          cameraMessage = "Preview only — virtual camera disconnected: \(error.localizedDescription)"
        }
      }
      frames &+= 1
      if now - lastPublished >= 0.25 {
        lastPublished = now
        let (sourceDrops, captureDrops) = stateLock.withLock { (self.sourceDrops, callbackDrops) }
        previewRenderer?.refreshPerformanceMetrics()
        let preview = previewRenderer?.diagnosticsSnapshot()
        let previewDrops = (preview?.stagingDrops ?? 0) + (preview?.replaced ?? 0) + (preview?.failed ?? 0) + (preview?.rendererDropped ?? 0) + (preview?.rendererCorrupted ?? 0)
        let elapsed = now - rateStart
        let fps = rateStart == 0 ? 0 : Double(frames - rateFrames) / elapsed
        rateStart = now
        rateFrames = frames
        if now - lastLogged >= 5 {
          lastLogged = now
          let packed = processor.packedInputDiagnostics
          logger.notice("Packed input noCopy=\(packed.noCopyFrames) copiedFallback=\(packed.copiedFrames)")
          logger.notice("Live fps=\(fps) processed=\(self.frames) displayed=\(preview?.rendererFrames ?? 0) sourceDrops=\(sourceDrops) captureDrops=\(captureDrops) poolDrops=\(self.poolDrops) previewDrops=\(previewDrops)")
        }
        publish(CaptureUpdate(message: configuration.applyLUT ? "LUT applied to live feed" : "Live feed — LUT off",
          input: "3840 × 2160 · \(VideoContract.fourCC(CVPixelBufferGetPixelFormatType(input))) · 10-bit 4:2:2",
          frames: frames, dropped: sourceDrops + captureDrops + poolDrops + cameraDrops, processingMS: (ProcessInfo.processInfo.systemUptime - now) * 1000,
          previewDelivered: true, sourceDrops: sourceDrops, captureDrops: captureDrops, poolDrops: poolDrops, cameraDrops: cameraDrops,
          previewDrops: previewDrops, previewFrames: preview?.enqueued ?? frames, outputFPS: fps,
          displayedFrames: preview?.rendererFrames ?? 0, rendererDrops: preview?.rendererDropped ?? 0,
          previewError: preview?.lastError, cameraOutputActive: cameraConnected, cameraMessage: cameraMessage), token: token)
      }
    } catch VideoError.outputBackPressure {
      poolDrops &+= 1
    } catch { fail(error.localizedDescription, token: token) }
  }
}

// The SDK-backed immutable frame remains retained until GPU and preview work
// finish. It is never mutated by this controller or another accepted frame.
private struct CapturedFrame: @unchecked Sendable {
  let image: CVPixelBuffer
  let pts: CMTime
  let receivedAt: Double
}

// Injection exercises the same production controller and data path with
// deterministic driver/consumer behavior; live resources are queue-confined.
struct CaptureServices: @unchecked Sendable {
  var start: (String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void
  var stop: () -> Void
  var connect: (PipelineConfiguration, OSType) throws -> Void
  var disconnect: () -> Void
  var send: (CMSampleBuffer) throws -> Bool
  var preview: (CMSampleBuffer) -> Void = { _ in }
  var didProcess: (Double, Double) -> Void = { _, _ in }

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
      send: { try sink.send($0) })
  }
}

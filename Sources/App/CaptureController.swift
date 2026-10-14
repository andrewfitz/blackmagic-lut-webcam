@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct CaptureUpdate: @unchecked Sendable {
  var message: String
  var input: String = "No signal"
  var frames: UInt64 = 0
  var dropped: UInt64 = 0
  var processingMS: Double = 0
  var preview: CGImage?
  var stopped = false
}

// All resources and configuration live on this serial queue. AVFoundation
// discards late frames instead of accumulating a second processing backlog.
final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.ultrastudiolut.capture", qos: .userInteractive)
  private let session = AVCaptureSession()
  private let sink = CameraSink()
  private var processor: LUTProcessor?
  private var running = false
  private var frames: UInt64 = 0
  private var dropped: UInt64 = 0
  private var lastPublished: Double = 0
  private var lastReceived: Double = 0
  private var frameRateGate = FrameRateGate()
  private var configuration = PipelineConfiguration()
  private var watchdog: DispatchSourceTimer?
  var onUpdate: ((CaptureUpdate) -> Void)?

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
    queue.async {
      do {
        self.stopOnQueue()
        if self.processor == nil { self.processor = try LUTProcessor() }
        self.configuration = configuration
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) else {
          throw VideoError.message("UltraStudio is disconnected. Refresh the input list.")
        }
        let inputDuration = configuration.inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
        let rate = 1 / inputDuration.seconds
        guard let format = device.formats.first(where: {
          let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
          return dimensions.width == 3840 && dimensions.height == 2160 &&
            VideoContract.tenBit422.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription)) &&
            $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= rate + 0.01 && $0.maxFrameRate >= rate - 0.01 }
        }) else {
          throw VideoError.message("The driver does not expose 3840 × 2160 10-bit 4:2:2 at this frame rate. A direct DeckLink SDK capture adapter is needed; no 8-bit fallback is used.")
        }
        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }
        self.session.inputs.forEach { self.session.removeInput($0) }
        self.session.outputs.forEach { self.session.removeOutput($0) }
        guard self.session.canSetSessionPreset(.hd4K3840x2160) else {
          throw VideoError.message("The capture session does not support 4K.")
        }
        self.session.sessionPreset = .hd4K3840x2160
        let input = try AVCaptureDeviceInput(device: device)
        guard self.session.canAddInput(input) else { throw VideoError.message("UltraStudio cannot be opened. Close other capture apps.") }
        self.session.addInput(input)
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = inputDuration
        device.activeVideoMaxFrameDuration = inputDuration
        device.unlockForConfiguration()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard self.session.canAddOutput(output) else { throw VideoError.message("Video output cannot be added.") }
        self.session.addOutput(output)
        guard let pixelFormat = VideoContract.tenBit422.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) else {
          throw VideoError.message("No 10-bit 4:2:2 capture output is available from the macOS driver.")
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.setSampleBufferDelegate(self, queue: self.queue)
        try self.sink.connect(configuration: configuration,
          passthroughFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription))
        self.frameRateGate = FrameRateGate()
        self.frames = 0
        self.dropped = 0
        self.lastReceived = ProcessInfo.processInfo.systemUptime
        // Start after configuration has committed.
        self.queue.async {
          self.session.startRunning()
          self.running = true
          self.publish(CaptureUpdate(message: "Waiting for 4K 10-bit signal…"))
          let timer = DispatchSource.makeTimerSource(queue: self.queue)
          timer.schedule(deadline: .now() + 2, repeating: 1)
          timer.setEventHandler { [weak controller = self] in
            guard let self = controller, self.running else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastReceived > 2 {
              self.fail("No video signal for two seconds. Check the FX3 HDMI output and selected frame rate.")
            }
          }
          self.watchdog = timer
          timer.resume()
        }
      } catch { self.fail(error.localizedDescription) }
    }
  }

  func stop() { queue.async { self.stopOnQueue(); self.publish(CaptureUpdate(message: "Stopped", stopped: true)) } }

  private func stopOnQueue() {
    running = false
    watchdog?.cancel()
    watchdog = nil
    if session.isRunning { session.stopRunning() }
    sink.disconnect()
  }

  private func fail(_ message: String) {
    stopOnQueue()
    publish(CaptureUpdate(message: message, stopped: true))
  }

  private func publish(_ update: CaptureUpdate) {
    DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection) {
    guard running, let input = CMSampleBufferGetImageBuffer(sampleBuffer), let processor else { return }
    let now = ProcessInfo.processInfo.systemUptime
    lastReceived = now
    guard CVPixelBufferGetWidth(input) == 3840, CVPixelBufferGetHeight(input) == 2160,
      VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(input)) else {
      fail("Input changed from 4K 10-bit 4:2:2. Capture stopped to preserve source precision.")
      return
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid, pts.isNumeric else { fail("Camera supplied an invalid frame timestamp."); return }
    do {
      let rendered = try processor.process(input, configuration: configuration)
      // Frame-rate reduction is last: the full-resolution LUT, optional
      // Lanczos, and optional chroma/bit-depth conversion have completed.
      guard frameRateGate.shouldDeliver(pts, duration: configuration.duration) else { return }
      // CMIO uses host time. The source cadence is selected using camera PTS;
      // virtual-camera PTS is monotonic host-clock time, never SMPTE timecode.
      let sample = try VideoContract.sample(rendered, at: CMClockGetTime(CMClockGetHostTimeClock()), duration: configuration.duration)
      if try sink.send(sample) { frames += 1 } else { dropped += 1 }
      if now - lastPublished >= 0.25 {
        lastPublished = now
        let preview = processor.context.createCGImage(CIImage(cvPixelBuffer: rendered, options: [.colorSpace: NSNull()]),
          from: CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height),
          format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
        publish(CaptureUpdate(message: configuration.applyLUT ? "Sending LUT image to virtual camera" : "Sending ungraded log (LUT off)",
          input: "3840 × 2160 · \(VideoContract.fourCC(CVPixelBufferGetPixelFormatType(input))) · 10-bit 4:2:2",
          frames: frames, dropped: dropped, processingMS: (ProcessInfo.processInfo.systemUptime - now) * 1000,
          preview: preview))
      }
    } catch { fail(error.localizedDescription) }
  }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection) { dropped += 1 }
}

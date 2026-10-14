import CoreMedia
import CoreVideo
import Foundation
import XCTest

// Exercise the real pixel processor, rational cadence selector, and sample
// construction together. These checks need neither capture hardware nor an
// installed/signed camera extension, and never store source imagery on disk.
@objcMembers final class EndToEndChecks: XCTestCase {
  fileprivate static func source(luma: (Int) -> UInt16 = { _ in 283 }) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
      &buffer)
    XCTAssertEqual(status, kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane) / MemoryLayout<UInt16>.stride
      var row = [UInt16](repeating: 512 << 6, count: stride)
      if plane == 0 {
        for x in 0..<3840 { row[x] = luma(x) << 6 }
      }
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane))
      row.withUnsafeBytes { bytes in
        for y in 0..<2160 {
          memcpy(base.advanced(by: y * bytes.count), bytes.baseAddress!, bytes.count)
        }
      }
    }
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return image
  }

  private func luma(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
    if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
      return Int(row.assumingMemoryBound(to: UInt8.self)[x])
    }
    return Int(row.assumingMemoryBound(to: UInt16.self)[x] >> 6)
  }

  func testAllSwitchesAndBothRatesProduceUsableSamples() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(transform: { 1 - $0 })))
    let input = try Self.source()
    // Every checkbox is independent, including rate reduction. Test both
    // source rates: reducing a 29.97 source must never halve it again.
    for inputFast in [false, true] {
      for bits in 0..<16 {
        try autoreleasepool {
          let config = PipelineConfiguration(applyLUT: bits & 1 != 0, downscale: bits & 2 != 0,
            convertTo420: bits & 4 != 0, reduceFrameRate: bits & 8 != 0, inputFast: inputFast)
          let output = try processor.process(input, configuration: config)
          XCTAssertEqual(CVPixelBufferGetWidth(output), bits & 2 != 0 ? 1920 : 3840)
          XCTAssertEqual(CVPixelBufferGetHeight(output), bits & 2 != 0 ? 1080 : 2160)
          XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), bits & 4 != 0 ?
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
          let expectedCode = config.convertTo420 ? (config.applyLUT ? 180 : 71) : (config.applyLUT ? 721 : 283)
          for point in [(0, 0), (config.width / 2, config.height / 2), (config.width - 1, config.height - 1)] {
            XCTAssertEqual(Double(try luma(output, x: point.0, y: point.1)), Double(expectedCode), accuracy: 1,
              "Constant neutral image must survive processing and scaling, flags=\(bits), inputFast=\(inputFast)")
          }
          if config.untouched { XCTAssertTrue(output === input) }

          let inputDuration = inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          let expectedDuration = CMTime(value: 1001, timescale: inputFast && bits & 8 == 0 ? 60_000 : 30_000)
          var gate = FrameRateGate()
          var delivered = [CMTime]()
          let hostOrigin = CMTime(value: 120, timescale: 1)
          for frame in 0..<6 {
            let sourcePTS = CMTimeMultiply(inputDuration, multiplier: Int32(frame))
            guard gate.shouldDeliver(sourcePTS, duration: config.duration) else { continue }
            let outputPTS = CMTimeAdd(hostOrigin, sourcePTS)
            let sample = try VideoContract.sample(output, at: outputPTS, duration: config.duration)
            XCTAssertTrue(CMSampleBufferDataIsReady(sample))
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === output)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), outputPTS)
            XCTAssertEqual(CMSampleBufferGetDuration(sample), expectedDuration)
            XCTAssertFalse(CMSampleBufferGetDecodeTimeStamp(sample).isValid)
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let size = CMVideoFormatDescriptionGetDimensions(description)
            XCTAssertEqual(size.width, Int32(config.width))
            XCTAssertEqual(size.height, Int32(config.height))
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), CVPixelBufferGetPixelFormatType(output))
            delivered.append(outputPTS)
          }
          XCTAssertEqual(delivered.count, inputFast && config.reduceFrameRate ? 3 : 6)
          for index in 1..<delivered.count {
            XCTAssertEqual(CMTimeSubtract(delivered[index], delivered[index - 1]), expectedDuration)
          }
        }
      }
    }
  }

  func testNoLUTFileNeededWithEveryOtherSwitchCombination() throws {
    let processor = try LUTProcessor()
    let input = try Self.source()
    for bits in 0..<8 {
      try autoreleasepool {
        let config = PipelineConfiguration(applyLUT: false, downscale: bits & 1 != 0,
          convertTo420: bits & 2 != 0, reduceFrameRate: bits & 4 != 0, inputFast: true)
        let output = try processor.process(input, configuration: config)
        let sample = try VideoContract.sample(output, at: .zero, duration: config.duration)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(Double(try luma(output, x: config.width / 2, y: config.height / 2)),
          config.convertTo420 ? 71 : 283, accuracy: 1)
      }
    }
    XCTAssertThrowsError(try processor.process(input, configuration: PipelineConfiguration(
      applyLUT: true, downscale: false, convertTo420: false, reduceFrameRate: false, inputFast: true)),
      "An enabled, missing LUT must report an error instead of reading an uninitialized cube")
  }

  func testLUTConsumesTenBitPrecisionBeforeEightBitQuantization() throws {
    let processor = try LUTProcessor()
    // A domain expansion makes adjacent 10-bit log levels distinguishable in
    // final 8-bit output. Early 8-bit conversion would irreversibly collapse
    // most of these 80 levels, even though the final file format looks right.
    let cube = cubeText().replacingOccurrences(of: "LUT_3D_SIZE 2",
      with: "LUT_3D_SIZE 2\nDOMAIN_MIN 0.35 0.35 0.35\nDOMAIN_MAX 0.55 0.55 0.55")
    try processor.load(CubeLUT(text: cube))
    let input = try Self.source { UInt16(400 + $0 % 80) }
    let config = PipelineConfiguration(applyLUT: true, downscale: false,
      convertTo420: true, reduceFrameRate: false, inputFast: true)
    let output = try processor.process(input, configuration: config)
    var levels = Set<Int>()
    for x in 0..<80 {
      let actual = try luma(output, x: x, y: 1080)
      let logRGB = Double(400 + x - 64) / 876
      let expected = 16 + 219 * ((logRGB - 0.35) / 0.2)
      XCTAssertEqual(Double(actual), expected, accuracy: 1)
      levels.insert(actual)
    }
    XCTAssertEqual(levels.count, 80, "Every adjacent source level must reach the LUT before output quantization")
    let sample = try VideoContract.sample(output, at: VideoContract.fastDuration, duration: config.duration)
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMFormatDescriptionGetExtension(description,
      extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertEqual(CMFormatDescriptionGetExtension(description,
      extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
      kCVImageBufferTransferFunction_ITU_R_709_2 as String)
  }

  func testPoolBackpressureIsBoundedAndRecoversAfterConsumerReleases() throws {
    let processor = try LUTProcessor()
    let input = try Self.source()
    let config = PipelineConfiguration(applyLUT: false, downscale: true,
      convertTo420: true, reduceFrameRate: false, inputFast: true)
    var retained = [CVPixelBuffer]()
    for frame in 0..<8 {
      let output = try processor.process(input, configuration: config)
      // Simulate consumer retention, as would happen with an occupied CMIO
      // queue. Distinct frames must not overwrite already published buffers.
      XCTAssertFalse(retained.contains { $0 === output })
      let sample = try VideoContract.sample(output,
        at: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)), duration: config.duration)
      XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === output)
      retained.append(output)
    }
    XCTAssertThrowsError(try processor.process(input, configuration: config),
      "A stalled consumer must not cause unbounded allocation") { error in
      guard case VideoError.outputBackPressure = error else {
        XCTFail("Pool pressure must be distinguishable from fatal GPU errors: \(error)")
        return
      }
    }
    retained.removeAll()
    let recovered = try processor.process(input, configuration: config)
    XCTAssertEqual(Double(try luma(recovered, x: 960, y: 540)), 71, accuracy: 1)
  }

  func testCadenceSurvivesSourceLossInvalidTimesAndClockRestart() throws {
    var gate = FrameRateGate()
    let inputDuration = VideoContract.fastDuration
    let deliveredFrames = (0..<12).filter { frame in
      // Frame 2 would normally be delivered but is lost at capture. Frame 3
      // can be delivered next; the gate must avoid freezing after a gap.
      guard frame != 2 else { return false }
      return gate.shouldDeliver(CMTimeMultiply(inputDuration, multiplier: Int32(frame)),
        duration: VideoContract.slowDuration)
    }
    XCTAssertEqual(deliveredFrames, [0, 3, 5, 7, 9, 11])
    XCTAssertFalse(gate.shouldDeliver(.invalid, duration: VideoContract.slowDuration))
    XCTAssertFalse(gate.shouldDeliver(.indefinite, duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(.zero, duration: VideoContract.slowDuration),
      "A replacement source with a reset PTS must restart cadence immediately")
    XCTAssertFalse(gate.shouldDeliver(.zero, duration: VideoContract.slowDuration),
      "Duplicate timestamps must not be published twice")
    XCTAssertFalse(gate.shouldDeliver(inputDuration, duration: VideoContract.slowDuration))
    XCTAssertTrue(gate.shouldDeliver(VideoContract.slowDuration, duration: VideoContract.slowDuration))
  }
}

#if CAPTURE_LIFECYCLE_TESTS
// Only hardware/service boundaries are replaced. The real CaptureController,
// Metal processor, Core Image preview and CMSampleBuffer creation still run.
private final class CaptureHarness: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers = [(CVPixelBuffer, CMTime, Bool) -> Void]()
  private var stopTotal = 0
  private var disconnectTotal = 0
  private var sendTotal = 0
  private var attemptTotal = 0
  private var captureActive = false
  private var samples = [CMSampleBuffer]()
  private var latest: CMSampleBuffer?
  let startGate: DispatchSemaphore?
  let started: XCTestExpectation?
  let retainOutputs: Bool
  let failSending: Bool

  init(startGate: DispatchSemaphore? = nil, started: XCTestExpectation? = nil,
    retainOutputs: Bool = false, failSending: Bool = false) {
    self.startGate = startGate
    self.started = started
    self.retainOutputs = retainOutputs
    self.failSending = failSending
  }

  var starts: Int { lock.withLock { handlers.count } }
  var stops: Int { lock.withLock { stopTotal } }
  var disconnects: Int { lock.withLock { disconnectTotal } }
  var sent: Int { lock.withLock { sendTotal } }
  var attempts: Int { lock.withLock { attemptTotal } }
  var active: Bool { lock.withLock { captureActive } }
  var lastSample: CMSampleBuffer? { lock.withLock { latest } }

  func releaseOutputs() { lock.withLock { samples.removeAll(); latest = nil } }

  func emit(_ image: CVPixelBuffer, frame: Int, from generation: Int? = nil) {
    let handler = lock.withLock { handlers[generation ?? handlers.count - 1] }
    handler(image, CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)), true)
  }

  func services() -> CaptureServices {
    CaptureServices(
      start: { _, _, frames, _ in
        self.lock.withLock { self.handlers.append(frames); self.captureActive = true }
        self.started?.fulfill()
        if let gate = self.startGate {
          guard gate.wait(timeout: .now() + 5) == .success else {
            throw VideoError.message("Test did not release the blocked capture start")
          }
        }
      },
      stop: { self.lock.withLock { self.stopTotal += 1; self.captureActive = false } },
      connect: { _, _ in },
      disconnect: {
        self.lock.withLock { self.disconnectTotal += 1; self.samples.removeAll(); self.latest = nil }
      },
      send: { sample in
        try self.lock.withLock {
          self.attemptTotal += 1
          if self.failSending { throw VideoError.message("Synthetic consumer disconnected") }
          self.sendTotal += 1
          self.latest = sample
          if self.retainOutputs { self.samples.append(sample) }
          return true
        }
      })
  }
}

@objcMembers final class CaptureLifecycleChecks: XCTestCase {
  private let config = PipelineConfiguration(applyLUT: false, downscale: true,
    convertTo420: true, reduceFrameRate: false, inputFast: true)

  private func allowQueueWork(_ seconds: TimeInterval = 0.02) {
    let resumed = expectation(description: "Allow asynchronous capture/preview work")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { resumed.fulfill() }
    wait(for: [resumed], timeout: 3)
  }

  private func deliver(until target: Int, using harness: CaptureHarness,
    image: CVPixelBuffer, frame: inout Int) {
    let deadline = Date().addingTimeInterval(3)
    while harness.sent < target && Date() < deadline {
      harness.emit(image, frame: frame)
      frame += 1
      allowQueueWork()
    }
    XCTAssertEqual(harness.sent, target, "Capture must continue delivering through its real processing pipeline")
  }

  func testStopDuringBlockedStartCannotPublishLiveOrKeepResources() throws {
    let started = expectation(description: "Native start entered")
    let stopped = expectation(description: "Stop completed")
    let unexpectedLive = expectation(description: "Cancelled start must not deliver frames")
    unexpectedLive.isInverted = true
    let gate = DispatchSemaphore(value: 0)
    let harness = CaptureHarness(startGate: gate, started: started)
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop(); gate.signal() }
    controller.onUpdate = { update in
      if update.stopped { stopped.fulfill() }
      if update.frames > 0 { unexpectedLive.fulfill() }
    }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [started], timeout: 3)
    controller.stop()
    gate.signal()
    wait(for: [stopped], timeout: 3)
    XCTAssertEqual(harness.starts, 1)
    XCTAssertFalse(harness.active, "A cancelled in-flight Start must finish with the capture resource closed")
    harness.emit(try EndToEndChecks.source(), frame: 0, from: 0)
    wait(for: [unexpectedLive], timeout: 0.05)
    XCTAssertEqual(harness.sent, 0)
  }

  func testRestartRejectsFramesFromPreviousDriverCallback() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop() }
    let firstStart = expectation(description: "First start ready")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { firstStart.fulfill() }
    }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [firstStart], timeout: 3)
    let stopped = expectation(description: "First stop completed")
    controller.onUpdate = { if $0.stopped { stopped.fulfill() } }
    controller.stop()
    wait(for: [stopped], timeout: 3)
    let secondStart = expectation(description: "Second start ready")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { secondStart.fulfill() }
    }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [secondStart], timeout: 3)
    let delivered = expectation(description: "New generation frame processed")
    controller.onUpdate = { update in
      if update.frames > 0 {
        XCTAssertFalse(update.stopped)
        XCTAssertEqual(update.frames, 1)
        delivered.fulfill()
      }
    }
    harness.emit(try EndToEndChecks.source(), frame: 0, from: 0)
    harness.emit(try EndToEndChecks.source { _ in 721 }, frame: 0, from: 1)
    wait(for: [delivered], timeout: 3)
    XCTAssertEqual(harness.sent, 1)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(harness.lastSample)))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Double(pixels[960]), 180, accuracy: 1,
      "Old callbacks must not win the single-frame slot or overwrite the new source")
  }

  func testStalledConsumerPoolPressureDropsThenRecoversWithoutRestart() throws {
    let harness = CaptureHarness(retainOutputs: true)
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop(); harness.releaseOutputs() }
    let ready = expectation(description: "Start ready")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      XCTAssertFalse(update.stopped, "Backpressure must not be a fatal capture error")
    }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [ready], timeout: 3)
    let source = try EndToEndChecks.source()
    var frame = 0
    deliver(until: 8, using: harness, image: source, frame: &frame)
    harness.emit(source, frame: frame)
    frame += 1
    allowQueueWork(0.05)
    XCTAssertEqual(harness.sent, 8, "The ninth retained output must hit the eight-buffer cap")
    XCTAssertEqual(harness.stops, 1, "Capture must remain open while output buffers are occupied")
    harness.releaseOutputs()
    deliver(until: 9, using: harness, image: source, frame: &frame)
    XCTAssertEqual(harness.starts, 1, "Released consumer buffers must recover without restarting the device")
    XCTAssertEqual(harness.stops, 1)
  }

  func testConsumerDisconnectKeepsLocalPreviewRunning() throws {
    let harness = CaptureHarness(failSending: true)
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop() }
    let ready = expectation(description: "Start ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [ready], timeout: 3)
    let firstPreview = expectation(description: "Preview survives consumer disconnect")
    controller.onUpdate = { update in
      if update.frames == 1 {
        XCTAssertFalse(update.stopped)
        XCTAssertFalse(update.cameraOutputActive)
        XCTAssertNotNil(update.preview)
        XCTAssertTrue(update.cameraMessage.contains("Synthetic consumer disconnected"))
        firstPreview.fulfill()
      }
    }
    let source = try EndToEndChecks.source()
    harness.emit(source, frame: 0)
    wait(for: [firstPreview], timeout: 3)
    allowQueueWork(0.3)
    let secondPreview = expectation(description: "Subsequent local preview remains live")
    controller.onUpdate = { update in
      if update.frames == 2 {
        XCTAssertNotNil(update.preview)
        XCTAssertFalse(update.cameraOutputActive)
        XCTAssertFalse(update.stopped)
        secondPreview.fulfill()
      }
    }
    harness.emit(source, frame: 20)
    wait(for: [secondPreview], timeout: 3)
    XCTAssertEqual(harness.attempts, 1, "Do not keep writing to a disconnected virtual camera")
    XCTAssertEqual(harness.starts, 1)
    XCTAssertEqual(harness.stops, 1)
  }
}
#endif

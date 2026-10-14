import CoreMedia
import CoreVideo
import Darwin
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
    for frame in 0..<VideoContract.outputBufferLimit {
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
// Metal processor and post-pipeline CMSampleBuffer construction still run.
private final class CaptureHarness: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers = [(CVPixelBuffer, CMTime, Bool) -> Void]()
  private var automaticHandlers = [(CVPixelBuffer, CMTime, CMTime, Bool) -> Void]()
  private var connections = [(PipelineConfiguration, OSType)]()
  private var deliveryObserver: ((Int) -> Void)?
  private var stopTotal = 0
  private var disconnectTotal = 0
  private var sendTotal = 0
  private var attemptTotal = 0
  private var captureActive = false
  private var samples = [CMSampleBuffer]()
  private var latest: CMSampleBuffer?
  private var latestPreview: CMSampleBuffer?
  private var previewTotal = 0
  private var cameraSampleIDs = [ObjectIdentifier]()
  private var previewSampleIDs = [ObjectIdentifier]()
  private var previewTimes = [CMTime]()
  private var previewDurations = [CMTime]()
  private var processTimes = [Double]()
  private var queueWaitTimes = [Double]()
  let startGate: DispatchSemaphore?
  let started: XCTestExpectation?
  let retainOutputs: Bool
  let failSending: Bool
  let failConnecting: Bool

  init(startGate: DispatchSemaphore? = nil, started: XCTestExpectation? = nil,
    retainOutputs: Bool = false, failSending: Bool = false, failConnecting: Bool = false) {
    self.startGate = startGate
    self.started = started
    self.retainOutputs = retainOutputs
    self.failSending = failSending
    self.failConnecting = failConnecting
  }

  var starts: Int { lock.withLock { handlers.count + automaticHandlers.count } }
  var stops: Int { lock.withLock { stopTotal } }
  var disconnects: Int { lock.withLock { disconnectTotal } }
  var sent: Int { lock.withLock { sendTotal } }
  var attempts: Int { lock.withLock { attemptTotal } }
  var active: Bool { lock.withLock { captureActive } }
  var lastSample: CMSampleBuffer? { lock.withLock { latest } }
  var lastPreview: CMSampleBuffer? { lock.withLock { latestPreview } }
  var previewed: Int { lock.withLock { previewTotal } }
  var previewTiming: [(CMTime, CMTime)] { lock.withLock { Array(zip(previewTimes, previewDurations)) } }
  var cameraAndPreviewSamplesMatch: Bool { lock.withLock { cameraSampleIDs == previewSampleIDs } }
  var processingTiming: [(Double, Double)] { lock.withLock { Array(zip(processTimes, queueWaitTimes)) } }
  var negotiated: [(PipelineConfiguration, OSType)] { lock.withLock { connections } }

  func releaseOutputs() { lock.withLock { samples.removeAll(); latest = nil; latestPreview = nil } }
  func observeDelivery(_ observer: ((Int) -> Void)?) { lock.withLock { deliveryObserver = observer } }

  func emit(_ image: CVPixelBuffer, frame: Int, from generation: Int? = nil) {
    let handler = lock.withLock { handlers[generation ?? handlers.count - 1] }
    handler(image, CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)), true)
  }

  func emitAutomatic(_ image: CVPixelBuffer, at time: CMTime, duration: CMTime, from generation: Int? = nil) {
    let handler = lock.withLock { automaticHandlers[generation ?? automaticHandlers.count - 1] }
    handler(image, time, duration, true)
  }

  private func finishStart() throws {
    started?.fulfill()
    if let gate = startGate {
      guard gate.wait(timeout: .now() + 5) == .success else {
        throw VideoError.message("Test did not release the blocked capture start")
      }
    }
  }

  func services(automatic: Bool = false, previewConsumer: Bool = true) -> CaptureServices {
    var services = CaptureServices(
      start: { _, _, frames, _ in
        self.lock.withLock { self.handlers.append(frames); self.captureActive = true }
        try self.finishStart()
      },
      stop: { self.lock.withLock { self.stopTotal += 1; self.captureActive = false } },
      connect: { configuration, pixelFormat in
        try self.lock.withLock {
          self.connections.append((configuration, pixelFormat))
          if self.failConnecting { throw VideoError.message("Synthetic virtual camera unavailable") }
        }
      },
      disconnect: {
        self.lock.withLock { self.disconnectTotal += 1; self.samples.removeAll(); self.latest = nil }
      },
      send: { sample in
        let delivery: (Int, ((Int) -> Void)?) = try self.lock.withLock {
          self.attemptTotal += 1
          if self.failSending { throw VideoError.message("Synthetic consumer disconnected") }
          self.sendTotal += 1
          self.cameraSampleIDs.append(ObjectIdentifier(sample))
          self.latest = sample
          if self.retainOutputs { self.samples.append(sample) }
          return (self.sendTotal, self.deliveryObserver)
        }
        delivery.1?(delivery.0)
        return true
      },
      preview: { sample in
        self.lock.withLock {
          self.previewTotal += 1
          self.latestPreview = sample
          self.previewSampleIDs.append(ObjectIdentifier(sample))
          self.previewTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
          self.previewDurations.append(CMSampleBufferGetDuration(sample))
        }
      },
      didProcess: { processingMS, queueWaitMS in
        self.lock.withLock { self.processTimes.append(processingMS); self.queueWaitTimes.append(queueWaitMS) }
      })
    if !previewConsumer { services.preview = nil }
    if automatic {
      services.startAutomatic = { _, frames, _ in
        self.lock.withLock { self.automaticHandlers.append(frames); self.captureActive = true }
        try self.finishStart()
      }
    }
    return services
  }
}

private final class CaptureStatusRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var largestDropCount: UInt64 = 0
  private var stoppedMessages = [String]()
  private var updates = [CaptureUpdate]()

  func record(_ update: CaptureUpdate) {
    lock.withLock {
      largestDropCount = max(largestDropCount, update.dropped)
      updates.append(update)
      if update.stopped { stoppedMessages.append(update.message) }
    }
  }

  var drops: UInt64 { lock.withLock { largestDropCount } }
  var failures: [String] { lock.withLock { stoppedMessages } }
  var last: CaptureUpdate? { lock.withLock { updates.last } }
}

private final class PacedDriverMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var emittedTimes = [Double]()
  private var callbackCPU = [Double]()
  private var setup: kern_return_t?
  private var restored: kern_return_t?
  private var activePolicy = false
  private var cancelled = false

  init() {
    emittedTimes.reserveCapacity(180)
    callbackCPU.reserveCapacity(180)
  }

  func recordPolicy(_ result: kern_return_t, active: Bool) { lock.withLock { setup = result; activePolicy = active } }
  func recordRestore(_ result: kern_return_t) { lock.withLock { restored = result } }
  func recordCPU(_ ms: Double) { lock.withLock { callbackCPU.append(ms) } }
  var policySetup: kern_return_t? { lock.withLock { setup } }
  var policyRestore: kern_return_t? { lock.withLock { restored } }
  var policyActive: Bool { lock.withLock { activePolicy } }
  var cpuTimes: [Double] { lock.withLock { callbackCPU } }

  func record() { lock.withLock { emittedTimes.append(ProcessInfo.processInfo.systemUptime) } }
  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  var times: [Double] { lock.withLock { emittedTimes } }
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
    defer { harness.observeDelivery(nil) }
    while harness.sent < target && Date() < deadline {
      let next = harness.sent + 1
      let delivered = expectation(description: "Camera accepted output \(next)")
      harness.observeDelivery { count in if count == next { delivered.fulfill() } }
      harness.emit(image, frame: frame)
      frame += 1
      // Drive this pressure/recovery fixture from actual camera delivery rather
      // than adding a coalescible 20 ms main-queue timer between every sample.
      // The existing overall three-second completion deadline is unchanged.
      wait(for: [delivered], timeout: max(0.001, deadline.timeIntervalSinceNow))
    }
    XCTAssertEqual(harness.sent, target, "Capture must continue delivering through its real processing pipeline")
  }

  private func distribution(_ values: [Double]) -> String {
    let sorted = values.sorted()
    guard let first = sorted.first, let last = sorted.last else { return "count=0" }
    func percentile(_ fraction: Double) -> Double {
      sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
    return "count=\(sorted.count),min=\(first),p50=\(percentile(0.5)),p95=\(percentile(0.95)),max=\(last)"
  }

  private func awaitCondition(_ description: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() && Date() < deadline { allowQueueWork(0.01) }
    XCTAssertTrue(predicate(), description)
  }

  private func ready(_ controller: CaptureController, harness: CaptureHarness,
    configuration: PipelineConfiguration, pipelineEnabled: Bool = true, previewEnabled: Bool = true) {
    let started = expectation(description: "Capture start completed")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { started.fulfill() }
    }
    controller.start(deviceID: "synthetic", configuration: configuration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
    wait(for: [started], timeout: 5)
    XCTAssertEqual(harness.starts, 1)
  }

  private func assertCameraContract(_ harness: CaptureHarness, sample: CMSampleBuffer) throws {
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    let negotiated = try XCTUnwrap(harness.negotiated.last)
    XCTAssertEqual(negotiated.0.width, CVPixelBufferGetWidth(image))
    XCTAssertEqual(negotiated.0.height, CVPixelBufferGetHeight(image))
    XCTAssertEqual(negotiated.0.untouched ? negotiated.1 : negotiated.0.pixelFormat,
      CVPixelBufferGetPixelFormatType(image))
    XCTAssertEqual(negotiated.0.duration, CMSampleBufferGetDuration(sample),
      "Live mode changes must renegotiate the actual output before camera delivery")
  }

  private func assertNeutralCode(_ sample: CMSampleBuffer, expected: Int) throws {
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0))
    let center = CVPixelBufferGetWidth(image) / 2
    let actual = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ?
      Int(base.assumingMemoryBound(to: UInt8.self)[center]) :
      Int(base.assumingMemoryBound(to: UInt16.self)[center] >> 6)
    XCTAssertEqual(Double(actual), Double(expected), accuracy: 1)
  }

  func testCompleteBypassPreservesSourceAndCadenceThenRestoresAllSavedEffects() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services(automatic: true))
    defer { controller.onUpdate = nil; controller.stop() }
    let saved = PipelineConfiguration(applyLUT: true, downscale: true,
      convertTo420: true, reduceFrameRate: true, inputFast: false)
    ready(controller, harness: harness, configuration: saved, pipelineEnabled: false)
    let statuses = CaptureStatusRecorder()
    controller.onUpdate = { statuses.record($0) }
    let source = try EndToEndChecks.source()
    for frame in 0..<2 {
      harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)),
        duration: VideoContract.fastDuration)
      awaitCondition("Complete bypass must preserve every source frame") { harness.sent == frame + 1 }
      let raw = try XCTUnwrap(harness.lastSample)
      XCTAssertTrue(CMSampleBufferGetImageBuffer(raw) === source,
        "Already shareable input must remain bit-exact without LUT, scaling or conversion")
      XCTAssertEqual(CMSampleBufferGetDuration(raw), VideoContract.fastDuration,
        "Global bypass must also bypass the saved 59.94→29.97 reduction")
      try assertNeutralCode(raw, expected: 283)
      try assertCameraContract(harness, sample: raw)
    }
    awaitCondition("Status must describe the actual bypass output") { statuses.last?.pipelineEnabledApplied == false }
    XCTAssertTrue(statuses.last?.output.contains("3840") == true)
    XCTAssertTrue(statuses.last?.output.contains("59.94") == true)
    // Saved LUT-enabled settings cannot make complete bypass require a LUT.
    // Load it only when processing is about to be enabled.
    let loaded = expectation(description: "Saved nonlinear LUT ready")
    controller.load(try CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 }))) { result in
      if case .failure(let error) = result { XCTFail(error.localizedDescription) }
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
    controller.reconfigure(configuration: saved, pipelineEnabled: true)
    allowQueueWork()
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 2),
      duration: VideoContract.fastDuration)
    awaitCondition("Re-enabling must apply the saved options to live output") { harness.sent == 3 }
    let graded = try XCTUnwrap(harness.lastSample)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(graded))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 1080)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(CMSampleBufferGetDuration(graded), VideoContract.slowDuration)
    try assertNeutralCode(graded, expected: 30)
    try assertCameraContract(harness, sample: graded)
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 3),
      duration: VideoContract.fastDuration)
    allowQueueWork(0.05)
    XCTAssertEqual(harness.sent, 3, "The restored rate checkbox must select alternate source frames")
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 4),
      duration: VideoContract.fastDuration)
    awaitCondition("Restored cadence must continue") { harness.sent == 4 }
    awaitCondition("Applied status must follow real processed output") { statuses.last?.pipelineEnabledApplied == true }
    XCTAssertEqual(harness.starts, 1, "Changing pipeline state must not reopen the physical capture device")
    XCTAssertEqual(statuses.failures, [])
  }

  func testPreviewOffLeavesProcessedCameraOutputRunningAndCanReenable() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop() }
    ready(controller, harness: harness, configuration: config, previewEnabled: false)
    let statuses = CaptureStatusRecorder()
    controller.onUpdate = { statuses.record($0) }
    let source = try EndToEndChecks.source()
    harness.emit(source, frame: 0)
    awaitCondition("Camera must receive processed output with preview disabled") { harness.sent == 1 }
    XCTAssertEqual(harness.previewed, 0)
    XCTAssertFalse(statuses.last?.previewDelivered ?? true)
    let output = try XCTUnwrap(harness.lastSample)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(output))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try assertNeutralCode(output, expected: 71)
    XCTAssertGreaterThan(harness.processingTiming.count, 0)
    controller.setPreviewEnabled(true)
    allowQueueWork()
    harness.emit(source, frame: 1)
    awaitCondition("Preview can resume without altering the camera stream") { harness.sent == 2 && harness.previewed == 1 }
    XCTAssertTrue(harness.lastSample === harness.lastPreview)
    controller.setPreviewEnabled(false)
    allowQueueWork()
    harness.emit(source, frame: 2)
    awaitCondition("Camera must continue after preview is disabled again") { harness.sent == 3 }
    XCTAssertEqual(harness.previewed, 1)
    XCTAssertEqual(harness.starts, 1)
  }

  func testAutomaticSourceRateChangesUpdateActualMetadataAndCameraContract() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services(automatic: true))
    defer { controller.onUpdate = nil; controller.stop() }
    var saved = config
    saved.inputFast = false
    ready(controller, harness: harness, configuration: saved)
    let statuses = CaptureStatusRecorder()
    controller.onUpdate = { statuses.record($0) }
    let source = try EndToEndChecks.source()
    var pts = CMTime.zero
    for (index, duration) in [VideoContract.fastDuration, VideoContract.slowDuration, VideoContract.fastDuration].enumerated() {
      if index > 0 { pts = CMTimeAdd(pts, duration) }
      harness.emitAutomatic(source, at: pts, duration: duration)
      awaitCondition("Automatic source mode must deliver the new rate") { harness.sent == index + 1 }
      awaitCondition("Actual source duration must reach UI metadata") { statuses.last?.sourceDuration == duration }
      let sample = try XCTUnwrap(harness.lastSample)
      XCTAssertEqual(CMSampleBufferGetDuration(sample), duration,
        "Saved inputFast must not override detected source cadence")
      XCTAssertEqual(statuses.last?.inputFast, duration == VideoContract.fastDuration)
      let rate = duration == VideoContract.fastDuration ? "59.94" : "29.97"
      XCTAssertTrue(statuses.last?.input.contains(rate) == true)
      XCTAssertTrue(statuses.last?.output.contains(rate) == true)
      try assertCameraContract(harness, sample: sample)
    }
    XCTAssertEqual(statuses.last?.sourceDrops, 0, "Valid rate transitions must not count as missing source frames")
    XCTAssertEqual(harness.starts, 1, "Source detection is automatic within the existing capture lifetime")
    XCTAssertEqual(statuses.failures, [])
  }

  func testHotPixelOptionsPreserveExistingReducedCadence() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services(automatic: true))
    defer { controller.onUpdate = nil; controller.stop() }
    var options = config
    options.reduceFrameRate = true
    ready(controller, harness: harness, configuration: options)
    let source = try EndToEndChecks.source()
    harness.emitAutomatic(source, at: .zero, duration: VideoContract.fastDuration)
    awaitCondition("Initial reduced output must deliver") { harness.sent == 1 }
    harness.emitAutomatic(source, at: VideoContract.fastDuration, duration: VideoContract.fastDuration)
    allowQueueWork()
    XCTAssertEqual(harness.sent, 1)
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 2),
      duration: VideoContract.fastDuration)
    awaitCondition("Second reduced output must deliver") { harness.sent == 2 }
    let preceding = try XCTUnwrap(harness.lastSample)
    options.downscale = false
    options.convertTo420 = false
    controller.reconfigure(configuration: options, pipelineEnabled: true)
    allowQueueWork()
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 3),
      duration: VideoContract.fastDuration)
    allowQueueWork(0.05)
    XCTAssertEqual(harness.sent, 2,
      "A pixel format or resolution change cannot restart the gate and emit adjacent source frames")
    harness.emitAutomatic(source, at: CMTimeMultiply(VideoContract.fastDuration, multiplier: 4),
      duration: VideoContract.fastDuration)
    awaitCondition("New pixel contract must deliver at the existing reduced cadence") { harness.sent == 3 }
    let updated = try XCTUnwrap(harness.lastSample)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(updated))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 3840)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 2160)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(CMSampleBufferGetDuration(updated), VideoContract.slowDuration)
    XCTAssertEqual(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(updated),
      CMSampleBufferGetPresentationTimeStamp(preceding)).seconds,
      VideoContract.slowDuration.seconds, accuracy: 0.000000002)
    try assertNeutralCode(updated, expected: 283)
    try assertCameraContract(harness, sample: updated)
    XCTAssertTrue(harness.lastPreview === updated)
    XCTAssertEqual(harness.starts, 1)
  }

  func testSameRateSourceClockResetReanchorsToCurrentHostClock() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services(automatic: true))
    defer { controller.onUpdate = nil; controller.stop() }
    var bypass = config
    bypass.applyLUT = false
    bypass.downscale = false
    bypass.convertTo420 = false
    ready(controller, harness: harness, configuration: bypass, pipelineEnabled: false)
    let source = try EndToEndChecks.source()
    let origin = CMTime(value: 100, timescale: 1)
    harness.emitAutomatic(source, at: origin, duration: VideoContract.fastDuration)
    awaitCondition("Initial clock anchor must deliver") { harness.sent == 1 }
    harness.emitAutomatic(source, at: CMTimeAdd(origin, VideoContract.fastDuration), duration: VideoContract.fastDuration)
    awaitCondition("Source clock must advance normally") { harness.sent == 2 }
    let beforeReset = try XCTUnwrap(harness.lastSample)
    allowQueueWork(0.04)
    let hostBeforeReset = CMClockGetTime(CMClockGetHostTimeClock())
    // Backwards from the previous PTS, but still later than the original anchor:
    // comparing only against the first source frame cannot detect this reset.
    let resetPTS = CMTimeAdd(origin, CMTimeMultiplyByRatio(VideoContract.fastDuration, multiplier: 1, divisor: 2))
    harness.emitAutomatic(source, at: resetPTS, duration: VideoContract.fastDuration)
    awaitCondition("Same-rate backwards source PTS must restart delivery") { harness.sent == 3 }
    let resetSample = try XCTUnwrap(harness.lastSample)
    let emittedPTS = CMSampleBufferGetPresentationTimeStamp(resetSample)
    XCTAssertGreaterThanOrEqual(CMTimeCompare(emittedPTS, hostBeforeReset), 0,
      "Reset output must use the current host clock rather than the stale initial anchor")
    XCTAssertGreaterThan(CMTimeCompare(emittedPTS, CMSampleBufferGetPresentationTimeStamp(beforeReset)), 0,
      "A source timestamp reset must not make camera/preview timestamps go backwards")
    XCTAssertLessThanOrEqual(CMTimeCompare(emittedPTS, CMClockGetTime(CMClockGetHostTimeClock())), 0)
    XCTAssertEqual(CMSampleBufferGetDuration(resetSample), VideoContract.fastDuration)
    XCTAssertTrue(harness.lastPreview === resetSample)
    XCTAssertEqual(harness.starts, 1)
    try assertCameraContract(harness, sample: resetSample)
  }

  func testNonzeroSourceTimestampEpochCannotReachCameraOrPreview() throws {
    let harness = CaptureHarness()
    let controller = CaptureController(services: harness.services(automatic: true))
    defer { controller.onUpdate = nil; controller.stop() }
    ready(controller, harness: harness, configuration: config)
    let stopped = expectation(description: "Unsupported source clock epoch rejected")
    controller.onUpdate = { if $0.stopped { stopped.fulfill() } }
    let foreignClock = CMTime(value: 1001, timescale: 60_000, flags: .valid, epoch: 1)
    harness.emitAutomatic(try EndToEndChecks.source(), at: foreignClock, duration: VideoContract.fastDuration)
    wait(for: [stopped], timeout: 3)
    XCTAssertFalse(harness.active)
    XCTAssertEqual(harness.sent, 0)
    XCTAssertEqual(harness.previewed, 0)
    XCTAssertEqual(harness.processingTiming.count, 0, "Invalid clock epochs must be rejected before pixel processing")
  }

  func testNoCameraOrPreviewConsumerSkipsProcessingButStillValidatesSource() throws {
    let harness = CaptureHarness(failConnecting: true)
    let controller = CaptureController(services: harness.services(automatic: true, previewConsumer: false))
    defer { controller.onUpdate = nil; controller.stop() }
    ready(controller, harness: harness, configuration: config)
    let statuses = CaptureStatusRecorder()
    controller.onUpdate = { statuses.record($0) }
    let source = try EndToEndChecks.source()
    harness.emitAutomatic(source, at: .zero, duration: VideoContract.fastDuration)
    awaitCondition("Source information must still update with no output consumers") {
      statuses.last?.sourceDuration == VideoContract.fastDuration
    }
    XCTAssertEqual(harness.processingTiming.count, 0, "No visible preview/hook or camera means no pixel processing")
    XCTAssertEqual(harness.sent, 0)
    XCTAssertEqual(harness.previewed, 0)
    XCTAssertFalse(statuses.last?.previewDelivered ?? true)
    XCTAssertEqual(statuses.failures, [])
    let stopped = expectation(description: "Malformed input remains fatal without viewers")
    controller.onUpdate = { if $0.stopped { stopped.fulfill() } }
    var malformed: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      nil, &malformed), kCVReturnSuccess)
    harness.emitAutomatic(try XCTUnwrap(malformed), at: VideoContract.fastDuration, duration: VideoContract.fastDuration)
    wait(for: [stopped], timeout: 3)
    XCTAssertEqual(harness.processingTiming.count, 0)
    XCTAssertFalse(harness.active)
  }

  func testTwelveFrameAdmissionLimitIsBoundedAndRecoversAfterBurst() throws {
    let entered = expectation(description: "Capture queue held inside native start")
    let gate = DispatchSemaphore(value: 0)
    let harness = CaptureHarness(startGate: gate, started: entered)
    let controller = CaptureController(services: harness.services())
    let statuses = CaptureStatusRecorder()
    defer { controller.onUpdate = nil; controller.stop(); gate.signal() }
    controller.onUpdate = { statuses.record($0) }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [entered], timeout: 5)
    let source = try EndToEndChecks.source()
    for frame in 0..<13 { harness.emit(source, frame: frame) }
    XCTAssertEqual(harness.sent, 0, "The held processing queue cannot consume the admission burst yet")
    gate.signal()
    awaitCondition("Exactly twelve admitted frames must drain") { harness.sent == 12 }
    XCTAssertEqual(harness.previewed, 12)
    awaitCondition("Overflow must be visible in status") { statuses.last?.captureDrops == 1 }
    XCTAssertEqual(statuses.drops, 1)
    XCTAssertEqual(statuses.last?.poolDrops, 0)
    XCTAssertEqual(statuses.last?.cameraDrops, 0)
    XCTAssertEqual(statuses.failures, [])
    // Admission exhaustion is transient: a drained slot accepts a new frame.
    harness.emit(source, frame: 13)
    awaitCondition("Capture must resume after its bounded queue drains") { harness.sent == 13 }
    XCTAssertEqual(harness.previewed, 13)
    XCTAssertTrue(harness.cameraAndPreviewSamplesMatch)
    XCTAssertEqual(harness.starts, 1)
    XCTAssertTrue(harness.active)
  }

  func testQueuedReconfigureCannotReconnectOrRenderAfterCaptureStop() throws {
    let entered = expectation(description: "Capture start held")
    let stopped = expectation(description: "Cancelled reconfigure settled")
    let gate = DispatchSemaphore(value: 0)
    let harness = CaptureHarness(startGate: gate, started: entered)
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop(); gate.signal() }
    controller.onUpdate = { if $0.stopped { stopped.fulfill() } }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [entered], timeout: 5)
    let initialConnections = harness.negotiated.count
    controller.reconfigure(configuration: config, pipelineEnabled: false)
    controller.stop()
    gate.signal()
    wait(for: [stopped], timeout: 5)
    harness.emit(try EndToEndChecks.source(), frame: 0)
    allowQueueWork(0.05)
    XCTAssertFalse(harness.active)
    XCTAssertEqual(harness.negotiated.count, initialConnections,
      "An obsolete config request must not reopen virtual output after Stop")
    XCTAssertEqual(harness.sent, 0)
    XCTAssertEqual(harness.previewed, 0)
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
    XCTAssertEqual(harness.previewed, 0)
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
    XCTAssertEqual(harness.previewed, 1)
    XCTAssertTrue(harness.cameraAndPreviewSamplesMatch,
      "Preview must receive the same post-pipeline sample that was passed to the camera")
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(harness.lastSample)))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Double(pixels[960]), 180, accuracy: 1,
      "Old callbacks must not win the single-frame slot or overwrite the new source")
  }

  func testFatalInputRejectsAlreadyQueuedFramesAndPreservesStoppedStatus() throws {
    let started = expectation(description: "Hold native start while frames enter the queue")
    let stopped = expectation(description: "Fatal input stopped capture")
    let unexpectedLive = expectation(description: "Queued frames must not render after a fatal input")
    unexpectedLive.isInverted = true
    let gate = DispatchSemaphore(value: 0)
    let harness = CaptureHarness(startGate: gate, started: started)
    let controller = CaptureController(services: harness.services())
    defer { controller.onUpdate = nil; controller.stop(); gate.signal() }
    controller.onUpdate = { update in
      if update.stopped {
        XCTAssertTrue(update.message.contains("Expected 4K 10-bit 4:2:2"))
        stopped.fulfill()
      }
      if update.frames > 0 { unexpectedLive.fulfill() }
    }
    controller.start(deviceID: "synthetic", configuration: config)
    wait(for: [started], timeout: 5)
    var malformed: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &malformed), kCVReturnSuccess)
    let valid = try EndToEndChecks.source()
    harness.emit(try XCTUnwrap(malformed), frame: 0)
    harness.emit(valid, frame: 1)
    harness.emit(valid, frame: 2)
    gate.signal()
    wait(for: [stopped], timeout: 5)
    wait(for: [unexpectedLive], timeout: 0.05)
    XCTAssertFalse(harness.active)
    XCTAssertEqual(harness.sent, 0)
    XCTAssertEqual(harness.previewed, 0,
      "A fatal frame must invalidate accepted work queued behind it, not only new callbacks")
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
    deliver(until: VideoContract.outputBufferLimit, using: harness, image: source, frame: &frame)
    harness.emit(source, frame: frame)
    frame += 1
    allowQueueWork(0.05)
    XCTAssertEqual(harness.sent, VideoContract.outputBufferLimit,
      "Retaining the entire shared output budget must reject the next output")
    XCTAssertEqual(harness.stops, 1, "Capture must remain open while output buffers are occupied")
    harness.releaseOutputs()
    deliver(until: VideoContract.outputBufferLimit + 1, using: harness, image: source, frame: &frame)
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
        XCTAssertTrue(update.cameraMessage.contains("Synthetic consumer disconnected"))
        firstPreview.fulfill()
      }
    }
    let source = try EndToEndChecks.source()
    harness.emit(source, frame: 0)
    wait(for: [firstPreview], timeout: 3)
    XCTAssertEqual(harness.previewed, 1)
    XCTAssertNotNil(harness.lastPreview)
    allowQueueWork(0.3)
    let secondPreview = expectation(description: "Subsequent local preview remains live")
    controller.onUpdate = { update in
      if update.frames == 2 {
        XCTAssertFalse(update.cameraOutputActive)
        XCTAssertFalse(update.stopped)
        secondPreview.fulfill()
      }
    }
    harness.emit(source, frame: 20)
    wait(for: [secondPreview], timeout: 3)
    XCTAssertEqual(harness.previewed, 2)
    let preview = try XCTUnwrap(harness.lastPreview)
    XCTAssertEqual(CMSampleBufferGetDuration(preview), VideoContract.fastDuration)
    let previewImage = try XCTUnwrap(CMSampleBufferGetImageBuffer(preview))
    XCTAssertEqual(CVPixelBufferGetWidth(previewImage), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(previewImage), 1080)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(previewImage), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(harness.attempts, 1, "Do not keep writing to a disconnected virtual camera")
    XCTAssertEqual(harness.starts, 1)
    XCTAssertEqual(harness.stops, 1)
  }

  func testPacedNativeTenBitFeedPreservesEverySelectedPreviewSample() throws {
    // Borrowed/non-IOSurface packed v210 follows the production capture path,
    // including its ~22 MB CPU→GPU upload. This is synthetic cadence evidence;
    // it cannot establish hardware transport or physical display smoothness.
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      nil, &buffer), kCVReturnSuccess)
    let source = try XCTUnwrap(buffer)
    XCTAssertNil(CVPixelBufferGetIOSurface(source))
    CVPixelBufferLockBaseAddress(source, [])
    let stride = CVPixelBufferGetBytesPerRow(source) / MemoryLayout<UInt32>.stride
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt32.self)
    var row = [UInt32](repeating: 0, count: stride)
    for x in Swift.stride(from: 0, to: 3840, by: 6) {
      let offset = x / 6 * 4
      row[offset] = 512 | (283 << 10) | (512 << 20)
      row[offset + 1] = 283 | (512 << 10) | (283 << 20)
      row[offset + 2] = 512 | (283 << 10) | (512 << 20)
      row[offset + 3] = 283 | (512 << 10) | (283 << 20)
    }
    row.withUnsafeBytes { bytes in
      for y in 0..<2160 { memcpy(base.advanced(by: y * stride), bytes.baseAddress!, bytes.count) }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

    let frameCount = 180
    for reduce in [false, true] {
      let harness = CaptureHarness()
      let statuses = CaptureStatusRecorder()
      let controller = CaptureController(services: harness.services())
      defer { controller.onUpdate = nil; controller.stop(); harness.releaseOutputs() }
      let loaded = expectation(description: "Nonlinear LUT uploaded")
      controller.load(try CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 }))) { result in
        if case .failure(let error) = result { XCTFail(error.localizedDescription) }
        loaded.fulfill()
      }
      wait(for: [loaded], timeout: 5)
      let ready = expectation(description: "Prewarmed native processing ready")
      controller.onUpdate = { update in
        statuses.record(update)
        if update.message.hasPrefix("Waiting") { ready.fulfill() }
      }
      let config = PipelineConfiguration(applyLUT: true, downscale: true,
        convertTo420: true, reduceFrameRate: reduce, inputFast: true)
      controller.start(deviceID: "synthetic:v210", configuration: config)
      wait(for: [ready], timeout: 5)
      let produced = expectation(description: "180 source frames at 59.94 fps")
      let producerMetrics = PacedDriverMetrics()
      let finished = DispatchSemaphore(value: 0)
      var timebase = mach_timebase_info_data_t()
      XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
      let tickInterval = VideoContract.fastDuration.seconds * 1_000_000_000 *
        Double(timebase.denom) / Double(timebase.numer)
      // A hardware-clock-like source must not acquire the unrelated ordinary
      // thread scheduling jitter we retain in the earlier failure receipts.
      // Only this dedicated, sleeping source thread receives a bounded Mach
      // time constraint. The production capture/GPU/render queues stay unchanged.
      // Apple: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/scheduler/scheduler.html
      let producer = Thread {
        let thread = pthread_mach_thread_np(pthread_self())
        let words = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        func ticks(_ seconds: Double) -> UInt32 {
          UInt32((seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)).rounded())
        }
        var policy = thread_time_constraint_policy_data_t(period: UInt32(tickInterval.rounded()),
          computation: ticks(0.0005), constraint: ticks(0.001), preemptible: 1)
        let setup = withUnsafeMutablePointer(to: &policy) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
            thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, words)
          }
        }
        defer {
          var standard: integer_t = 0
          producerMetrics.recordRestore(thread_policy_set(thread,
            thread_policy_flavor_t(THREAD_STANDARD_POLICY), &standard, 0))
          produced.fulfill()
          finished.signal()
        }
        var observed = thread_time_constraint_policy_data_t()
        var count = words
        var defaults: boolean_t = 0
        let read = withUnsafeMutablePointer(to: &observed) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
            thread_policy_get(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count, &defaults)
          }
        }
        let active = setup == KERN_SUCCESS && read == KERN_SUCCESS && defaults == 0 &&
          observed.period == policy.period && observed.computation == policy.computation &&
          observed.constraint == policy.constraint
        producerMetrics.recordPolicy(setup == KERN_SUCCESS ? read : setup, active: active)
        guard active else { return }
        let origin = mach_absolute_time()
        for frame in 0..<frameCount {
          let deadline = origin + UInt64((Double(frame) * tickInterval).rounded())
          while mach_absolute_time() < deadline && !producerMetrics.isCancelled {
            mach_wait_until(deadline)
          }
          if producerMetrics.isCancelled { break }
          var cpuStart = timespec()
          var cpuEnd = timespec()
          let startStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuStart)
          producerMetrics.record()
          harness.emit(source, frame: frame)
          let endStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuEnd)
          let ms = startStatus == 0 && endStatus == 0 ?
            Double(cpuEnd.tv_sec - cpuStart.tv_sec) * 1000 + Double(cpuEnd.tv_nsec - cpuStart.tv_nsec) / 1_000_000 : .infinity
          producerMetrics.recordCPU(ms)
        }
      }
      producer.qualityOfService = .userInteractive
      producer.start()
      wait(for: [produced], timeout: 6)
      producerMetrics.cancel()
      XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
      allowQueueWork(0.08)

      XCTAssertEqual(producerMetrics.policySetup, KERN_SUCCESS, "Controlled source policy setup/readback must succeed")
      XCTAssertTrue(producerMetrics.policyActive, "Requested bounded source scheduling policy must be active")
      XCTAssertEqual(producerMetrics.policyRestore, KERN_SUCCESS, "Source thread must restore ordinary scheduling before exiting")
      XCTAssertEqual(producerMetrics.cpuTimes.count, frameCount)
      XCTAssertLessThanOrEqual(producerMetrics.cpuTimes.max() ?? .infinity, 0.5,
        "Source callback work must stay within its declared 0.5 ms computation budget")
      let emissionTimes = producerMetrics.times
      XCTAssertEqual(emissionTimes.count, frameCount)
      let expectedSpan = Double(frameCount - 1) * VideoContract.fastDuration.seconds
      let actualSpan = (emissionTimes.last ?? 0) - (emissionTimes.first ?? 0)
      let intervalsMS = zip(emissionTimes.dropFirst(), emissionTimes).map { ($0 - $1) * 1000 }
      let latenessMS = emissionTimes.enumerated().map { index, time in
        (time - (emissionTimes.first ?? time) - Double(index) * VideoContract.fastDuration.seconds) * 1000
      }
      let processing = harness.processingTiming
      print("PACED_SOURCE_POLICY periodMS=\(VideoContract.fastDuration.seconds * 1000) computationMS=0.5 constraintMS=1 setup=\(String(describing: producerMetrics.policySetup)) restore=\(String(describing: producerMetrics.policyRestore)) callbackCPUms{\(distribution(producerMetrics.cpuTimes))}")
      print("PACED_PROFILE emissionIntervalMS{\(distribution(intervalsMS))} emissionLatenessMS{\(distribution(latenessMS))} processingMS{\(distribution(processing.map { $0.0 }))} queueWaitMS{\(distribution(processing.map { $0.1 }))}")
      XCTAssertEqual(actualSpan, expectedSpan, accuracy: 0.025,
        "Paced producer must independently demonstrate physical 59.94 callback cadence")

      let expected = reduce ? frameCount / 2 : frameCount
      XCTAssertEqual(harness.sent, expected, "Paced 59.94 input must not drop accepted camera frames")
      XCTAssertEqual(harness.previewed, expected,
        "Native preview must receive video cadence, independently of the 4 Hz status updates")
      XCTAssertTrue(harness.cameraAndPreviewSamplesMatch,
        "Every preview sample must be the exact output sample passed to the camera")
      XCTAssertEqual(statuses.drops, 0)
      XCTAssertEqual(statuses.failures, [])
      let timings = harness.previewTiming
      for index in timings.indices {
        XCTAssertEqual(timings[index].1, reduce ? VideoContract.slowDuration : VideoContract.fastDuration)
        if index > 0 {
          let interval = CMTimeSubtract(timings[index].0, timings[index - 1].0)
          XCTAssertEqual(interval.seconds, config.duration.seconds, accuracy: 0.000000002,
            "Camera and preview timestamps must follow source cadence rather than GPU completion jitter")
        }
      }
      let preview = try XCTUnwrap(harness.lastPreview)
      let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(preview))
      XCTAssertEqual(CVPixelBufferGetWidth(image), 1920)
      XCTAssertEqual(CVPixelBufferGetHeight(image), 1080)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      // One final pixel check validates that preview contains the actual LUT
      // result rather than an independently rendered/bypassed source image.
      CVPixelBufferLockBaseAddress(image, .readOnly)
      let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)[960]
      CVPixelBufferUnlockBaseAddress(image, .readOnly)
      XCTAssertEqual(Double(pixel), 16 + 219 * 0.0625, accuracy: 1)
      print("PACED_CAPTURE v210 3840x2160 source=59.94 output=\(reduce ? 29.97 : 59.94) produced=\(emissionTimes.count) emissionSpan=\(actualSpan) camera=\(harness.sent) preview=\(harness.previewed) reportedDrops=\(statuses.drops)")
    }
  }
}
#endif

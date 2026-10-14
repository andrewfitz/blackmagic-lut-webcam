import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

private final class PreviewTestCounters: @unchecked Sendable {
  let lock = NSLock()
  var received = 0
  var frames = 0
  var dropped = 0
  var corrupt = 0
  var emissionTimes: [Double] = []
  let factory = VideoSampleFactory()
  var originalSamples: [CMSampleBuffer] = []
}

@MainActor @objcMembers final class PreviewChecks: XCTestCase {
  private func source(width: Int, height: Int, format: OSType, shareable: Bool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = shareable ? [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary : nil
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    if CVPixelBufferIsPlanar(image) {
      for plane in 0..<CVPixelBufferGetPlaneCount(image) {
        let count = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
          memset(base, 128, count)
        } else {
          let words = base.assumingMemoryBound(to: UInt16.self)
          for x in 0..<(count / 2) { words[x] = UInt16(plane == 0 ? 400 : 512) << 6 }
        }
      }
    } else {
      let stride = CVPixelBufferGetBytesPerRow(image) / 4
      let words = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)
      for y in 0..<height {
        for x in Swift.stride(from: 0, to: width, by: 6) {
          let offset = y * stride + x / 6 * 4
          words[offset] = 512 | (400 << 10) | (512 << 20)
          words[offset + 1] = 400 | (512 << 10) | (400 << 20)
          words[offset + 2] = 512 | (400 << 10) | (512 << 20)
          words[offset + 3] = 400 | (512 << 10) | (400 << 20)
        }
      }
    }
    for (key, value) in [
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
      (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center),
    ] { CVBufferSetAttachment(image, key, value, .shouldPropagate) }
    return image
  }

  private func attach(_ renderer: VideoPreviewRenderer, x: CGFloat = 80) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: x, y: 80, width: 480, height: 270),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Synthetic video preview check"
    window.isReleasedWhenClosed = false
    window.contentView = renderer.makeView()
    window.orderFrontRegardless()
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    print("PREVIEW HOST windowVisible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) viewBounds=\(window.contentView?.bounds ?? .zero) viewVisibleRect=\(window.contentView?.visibleRect ?? .zero) appActive=\(NSApplication.shared.isActive)")
    return window
  }

  func testNativeRendererAcceptsEveryOutputFormatAtBothRates() throws {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
      reason: "Qualifying live video preview cadence")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    for (width, height, format, shareable) in [
      (1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, true),
      (1920, 1080, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, true),
      (3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, true),
      (3840, 2160, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, true),
      (3840, 2160, kCVPixelFormatType_422YpCbCr10, true),
      (3840, 2160, kCVPixelFormatType_422YpCbCr10, false),
    ] {
      let image = try source(width: width, height: height, format: format, shareable: shareable)
      for duration in [VideoContract.fastDuration, VideoContract.slowDuration] {
        let renderer = VideoPreviewRenderer(renderWhenUnattached: true)
        let window = attach(renderer)
        defer { renderer.flush(); window.close() }
        let count = duration == VideoContract.fastDuration ? 30 : 15
        let original = try VideoContract.sample(image, at: CMClockGetTime(CMClockGetHostTimeClock()), duration: duration)
        if !shareable {
          let prepared = expectation(description: "bounded raw transport preparation")
          let prepareStarted = ProcessInfo.processInfo.systemUptime
          renderer.prepareForInput(width: width, height: height, pixelFormat: format) { result in
            if case .failure(let error) = result { XCTFail("Prepare raw preview: \(error)") }
            prepared.fulfill()
          }
          wait(for: [prepared], timeout: 2)
          print("PREVIEW PREPARE \(VideoContract.fourCC(format)) elapsedMS=\((ProcessInfo.processInfo.systemUptime - prepareStarted) * 1000)")
        }
        let framesSent = expectation(description: "paced preview frames")
        let timerQueue = DispatchQueue(label: "preview-test.source", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        let sent = PreviewTestCounters()
        timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
        timer.setEventHandler {
          sent.emissionTimes.append(ProcessInfo.processInfo.systemUptime)
          // A live camera emits a fresh sample with advancing media time even
          // when the picture is static. Reusing one PTS for the entire burst
          // exercises duplicate-time decoder behavior rather than video rate.
          do {
            let timestamp = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(original),
              CMTimeMultiply(duration, multiplier: Int32(sent.received)))
            let sample = try sent.factory.sample(image, at: timestamp, duration: duration)
            sent.originalSamples.append(sample)
            renderer.enqueue(sample)
          } catch { XCTFail("Create paced preview sample: \(error)") }
          sent.received += 1
          if sent.received == count { timer.cancel(); framesSent.fulfill() }
        }
        timer.resume()
        wait(for: [framesSent], timeout: 2)
        // A retained FIFO is not a dropped-frame count. Give accepted work its
        // finite queue budget to complete before measuring native consumption.
        // Actual overflow/failure remains counted and still fails thresholds.
        let drainDeadline = Date(timeIntervalSinceNow:
          duration.seconds * Double(VideoContract.previewPendingLimit) + 0.25)
        while Date() < drainDeadline {
          let progress = renderer.diagnosticsSnapshot()
          if progress.pending == 0 && progress.enqueued + progress.replaced
            + progress.stagingDrops + progress.failed >= progress.received { break }
          RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let diagnostics = renderer.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.received, UInt64(count))
        XCTAssertGreaterThanOrEqual(diagnostics.enqueued, UInt64(count - 3), "Native preview must not remain at 4 Hz")
        XCTAssertEqual(diagnostics.failed, 0, diagnostics.lastError ?? "Renderer must support selected format")
        XCTAssertLessThanOrEqual(diagnostics.pending, VideoContract.previewPendingLimit, "Preview scheduling stalls must stay within its fixed FIFO budget")
        XCTAssertEqual(sent.originalSamples.count, count)
        for sample in sent.originalSamples {
          XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
            "Preview DisplayImmediately attachment must not mutate the camera sample")
        }
        let metricsLoaded = expectation(description: "native renderer performance metrics")
        let metricsResult = PreviewTestCounters()
        renderer.loadPerformanceMetrics { metrics in
          metricsResult.lock.withLock {
            metricsResult.frames = metrics?.totalNumberOfFrames ?? 0
            metricsResult.dropped = metrics?.numberOfDroppedFrames ?? 0
            metricsResult.corrupt = metrics?.numberOfCorruptedFrames ?? 0
          }
          metricsLoaded.fulfill()
        }
        wait(for: [metricsLoaded], timeout: 2)
        metricsResult.lock.withLock {
          let gaps = zip(sent.emissionTimes.dropFirst(), sent.emissionTimes).map { ($0 - $1) * 1000 }
          if let raw = diagnostics.firstRawCopy {
            print("PREVIEW RAW firstStageWallMS=\(diagnostics.firstStagingMS) firstStageCPUMS=\(diagnostics.firstStagingCPUMS) maxStageCPUMS=\(diagnostics.maxStagingCPUMS) copyMode=\(raw.mode) copyWallMS=\(raw.wallMS) copyCPUMS=\(raw.cpuMS) copyGPUMS=\(raw.gpuMS) rawInitWallMS=\(raw.initializationWallMS) rawInitCPUMS=\(raw.initializationCPUMS)")
          }
          print("PREVIEW \(width)x\(height) \(VideoContract.fourCC(format)) IOSurface=\(shareable) fps=\(1 / duration.seconds) received=\(diagnostics.received) enqueued=\(diagnostics.enqueued) replaced=\(diagnostics.replaced) waits=\(diagnostics.backPressure) rendererFrames=\(metricsResult.frames) dropped=\(metricsResult.dropped) corrupted=\(metricsResult.corrupt) sourceGapMinMS=\(gaps.min() ?? 0) sourceGapMaxMS=\(gaps.max() ?? 0) firstStageMS=\(diagnostics.firstStagingMS) maxStageMS=\(diagnostics.maxStagingMS) avgStageMS=\(diagnostics.stagingTotalMS / Double(max(1, diagnostics.stagingFrames))) queueWaitMaxMS=\(diagnostics.maxQueueWaitMS) readinessWaitMaxMS=\(diagnostics.maxReadinessWaitMS)")
          XCTAssertGreaterThanOrEqual(metricsResult.frames - metricsResult.dropped, count - 3, "Actual renderer must consume frames at video cadence")
          XCTAssertEqual(metricsResult.corrupt, 0)
        }
      }
    }
  }

  func testFastProducerIsBoundedAndFlushRestartsWithoutStaleFrames() throws {
    let renderer = VideoPreviewRenderer(renderWhenUnattached: true)
    let window = attach(renderer)
    defer { renderer.flush(); window.close() }
    let image = try source(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let sample = try VideoContract.sample(image, at: .zero, duration: VideoContract.fastDuration)
    for _ in 0..<2000 { renderer.enqueue(sample); XCTAssertLessThanOrEqual(renderer.diagnosticsSnapshot().pending, VideoContract.previewPendingLimit) }
    renderer.flush()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0)
    renderer.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().received, 1)
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, 1)
    XCTAssertEqual(renderer.diagnosticsSnapshot().failed, 0)
  }

  func testHiddenAndUnattachedPreviewDoesNoFrameWork() throws {
    let renderer = VideoPreviewRenderer()
    let image = try source(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let sample = try VideoContract.sample(image, at: .zero, duration: VideoContract.fastDuration)
    XCTAssertFalse(renderer.isVisible)
    for _ in 0..<100 { renderer.enqueue(sample) }
    XCTAssertEqual(renderer.diagnosticsSnapshot().received, 0)
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0)
    // Drive the lock-protected visibility contract without relying on a bare
    // command-line host's desktop/space classification. Actual AppKit window
    // notifications are verified in the built application separately.
    renderer.setVisibilityForTesting(true)
    renderer.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, 1)
    renderer.setVisibilityForTesting(false)
    XCTAssertFalse(renderer.isVisible)
    for _ in 0..<100 { renderer.enqueue(sample) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().received, 1)
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0)
    renderer.setVisibilityForTesting(true)
    XCTAssertTrue(renderer.isVisible)
    renderer.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, 2)
    renderer.setVisibilityForTesting(false)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertFalse(renderer.isVisible)
    renderer.enqueue(sample)
    XCTAssertEqual(renderer.diagnosticsSnapshot().received, 2)
  }

  func testFIFOPreservesBurstOrderAndFlushDiscardsOldGeneration() throws {
    let renderer = VideoPreviewRenderer(renderWhenUnattached: true)
    let window = attach(renderer)
    defer { renderer.flush(); window.close() }
    let image = try source(width: 640, height: 360,
      format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let factory = VideoSampleFactory()
    let duration = VideoContract.fastDuration
    let times = (0..<VideoContract.previewPendingLimit).map { CMTimeMultiply(duration, multiplier: Int32($0 + 100)) }
    for time in times { renderer.enqueue(try factory.sample(image, at: time, duration: duration)) }
    let deadline = Date(timeIntervalSinceNow: 2)
    while renderer.diagnosticsSnapshot().enqueued < UInt64(times.count) && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, UInt64(times.count), "The finite burst must survive native readiness stalls")
    XCTAssertEqual(renderer.diagnosticsSnapshot().replaced, 0)
    XCTAssertEqual(renderer.enqueuedTimesForTesting(), times, "FIFO must retain source presentation order")

    for index in 0..<2000 {
      renderer.enqueue(try factory.sample(image, at: CMTimeMultiply(duration, multiplier: Int32(index + 1000)), duration: duration))
      XCTAssertLessThanOrEqual(renderer.diagnosticsSnapshot().pending, VideoContract.previewPendingLimit)
    }
    XCTAssertGreaterThan(renderer.diagnosticsSnapshot().replaced, 0, "Overload must be counted rather than growing the queue")
    renderer.flush()
    let finalTime = CMTimeMultiply(duration, multiplier: 10_000)
    renderer.enqueue(try factory.sample(image, at: finalTime, duration: duration))
    let restartDeadline = Date(timeIntervalSinceNow: 2)
    while renderer.diagnosticsSnapshot().enqueued < 1 && Date() < restartDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, 1)
    XCTAssertEqual(renderer.enqueuedTimesForTesting(), [finalTime], "Old queued samples must not cross flush generation")
    renderer.setVisibilityForTesting(false)
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0, "Hidden preview must release every FIFO slot")
  }

  func testQueuedOldDrainCannotRenderNewSampleBeforeNativeFlush() throws {
    let renderer = VideoPreviewRenderer(renderWhenUnattached: true)
    let window = attach(renderer)
    defer { renderer.flush(); window.close() }
    let image = try source(width: 640, height: 360,
      format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    renderer.blockQueueForTesting(entered: entered, release: release)
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    defer { release.signal() }
    let oldTime = CMTime(value: 1001, timescale: 60_000)
    let newTime = CMTime(value: 100_100, timescale: 60_000)
    renderer.enqueue(try VideoContract.sample(image, at: oldTime, duration: VideoContract.fastDuration))
    renderer.flush()
    renderer.enqueue(try VideoContract.sample(image, at: newTime, duration: VideoContract.fastDuration))
    release.signal()
    let deadline = Date(timeIntervalSinceNow: 2)
    while renderer.diagnosticsSnapshot().enqueued < 1 && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(renderer.enqueuedTimesForTesting(), [newTime])
    XCTAssertEqual(renderer.enqueuedFlushNumbersForTesting(), [1],
      "The new frame must enqueue after native flush, never before it")
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0)
  }

  func testMainAndMiniPreviewHaveIndependentVisibilityAndLayers() throws {
    let main = VideoPreviewRenderer(), mini = VideoPreviewRenderer()
    let mainView = main.makeView(), miniView = mini.makeView()
    let mainLayer = try XCTUnwrap(mainView.layer?.sublayers?.first)
    let miniLayer = try XCTUnwrap(miniView.layer?.sublayers?.first)
    XCTAssertFalse(mainLayer === miniLayer, "A layer cannot serve two simultaneous preview surfaces")
    let image = try source(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let sample = try VideoContract.sample(image, at: .zero, duration: VideoContract.fastDuration)
    main.setVisibilityForTesting(true); mini.setVisibilityForTesting(true)
    main.enqueue(sample); mini.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(main.diagnosticsSnapshot().enqueued, 1)
    XCTAssertEqual(mini.diagnosticsSnapshot().enqueued, 1)
    main.setVisibilityForTesting(false)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertFalse(main.isVisible)
    XCTAssertTrue(mini.isVisible)
    main.enqueue(sample); mini.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(main.diagnosticsSnapshot().enqueued, 1)
    XCTAssertEqual(mini.diagnosticsSnapshot().enqueued, 2)
    XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false))
  }
}

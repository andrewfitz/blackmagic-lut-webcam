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

  private func attach(_ renderer: VideoPreviewRenderer) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 270),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Synthetic video preview check"
    window.isReleasedWhenClosed = false
    window.contentView = renderer.makeView()
    window.orderFrontRegardless()
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  func testNativeRendererAcceptsEveryOutputFormatAtBothRates() throws {
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
        let renderer = VideoPreviewRenderer()
        let window = attach(renderer)
        defer { renderer.flush(); window.close() }
        let count = duration == VideoContract.fastDuration ? 30 : 15
        let original = try VideoContract.sample(image, at: CMClockGetTime(CMClockGetHostTimeClock()), duration: duration)
        let framesSent = expectation(description: "paced preview frames")
        let timerQueue = DispatchQueue(label: "preview-test.source")
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let sent = PreviewTestCounters()
        timer.schedule(deadline: .now(), repeating: duration.seconds, leeway: .milliseconds(1))
        timer.setEventHandler {
          renderer.enqueue(original)
          sent.received += 1
          if sent.received == count { timer.cancel(); framesSent.fulfill() }
        }
        timer.resume()
        wait(for: [framesSent], timeout: 2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let diagnostics = renderer.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.received, UInt64(count))
        XCTAssertGreaterThanOrEqual(diagnostics.enqueued, UInt64(count - 3), "Native preview must not remain at 4 Hz")
        XCTAssertEqual(diagnostics.failed, 0, diagnostics.lastError ?? "Renderer must support selected format")
        XCTAssertLessThanOrEqual(diagnostics.pending, 1)
        XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(original, createIfNecessary: false),
          "Preview DisplayImmediately attachment must not mutate the camera sample")
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
          print("PREVIEW \(width)x\(height) \(VideoContract.fourCC(format)) IOSurface=\(shareable) fps=\(1 / duration.seconds) received=\(diagnostics.received) enqueued=\(diagnostics.enqueued) replaced=\(diagnostics.replaced) waits=\(diagnostics.backPressure) rendererFrames=\(metricsResult.frames) dropped=\(metricsResult.dropped) corrupted=\(metricsResult.corrupt)")
          XCTAssertGreaterThanOrEqual(metricsResult.frames - metricsResult.dropped, count - 3, "Actual renderer must consume frames at video cadence")
          XCTAssertEqual(metricsResult.corrupt, 0)
        }
      }
    }
  }

  func testFastProducerIsBoundedAndFlushRestartsWithoutStaleFrames() throws {
    let renderer = VideoPreviewRenderer()
    let window = attach(renderer)
    defer { renderer.flush(); window.close() }
    let image = try source(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, shareable: true)
    let sample = try VideoContract.sample(image, at: .zero, duration: VideoContract.fastDuration)
    for _ in 0..<2000 { renderer.enqueue(sample); XCTAssertLessThanOrEqual(renderer.diagnosticsSnapshot().pending, 1) }
    renderer.flush()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().pending, 0)
    renderer.enqueue(sample)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(renderer.diagnosticsSnapshot().received, 1)
    XCTAssertEqual(renderer.diagnosticsSnapshot().enqueued, 1)
    XCTAssertEqual(renderer.diagnosticsSnapshot().failed, 0)
  }
}

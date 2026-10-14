import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import SwiftUI

// The preview consumes the exact post-pipeline sample sent to the camera. The
// native video renderer performs GPU-backed display conversion and ColorSync;
// no CGImage readback, second LUT, pixel conversion, or SwiftUI frame state.
final class VideoPreviewRenderer: @unchecked Sendable {
  struct Diagnostics: Sendable {
    var received: UInt64 = 0
    var enqueued: UInt64 = 0
    var replaced: UInt64 = 0
    var backPressure: UInt64 = 0
    var stagingDrops: UInt64 = 0
    var failed: UInt64 = 0
    var pending = 0
    var lastError: String?
    // Apple's performance counters belong to the renderer's lifetime, including
    // frames displayed before flush. Keep that scope explicit and never combine
    // these with per-run queue counters as though flush reset the native API.
    var rendererFrames: UInt64 = 0
    var rendererDropped: UInt64 = 0
    var rendererCorrupted: UInt64 = 0
#if CAPTURE_LIFECYCLE_TESTS
    var firstStagingMS = 0.0
    var maxStagingMS = 0.0
    var stagingTotalMS = 0.0
    var stagingFrames = 0
    var maxQueueWaitMS = 0.0
    var maxReadinessWaitMS = 0.0
    var firstStagingCPUMS = 0.0
    var maxStagingCPUMS = 0.0
    var firstRawCopy: GPURawFrameCopy.Timing?
#endif
  }

  @MainActor fileprivate let displayLayer: AVSampleBufferDisplayLayer
  private let videoRenderer: AVSampleBufferVideoRenderer
  private let queue = DispatchQueue(label: "org.ultrastudiolut.preview", qos: .userInteractive)
  private let lock = NSLock()
  private var stager = CameraFrameStager()
  private var generation: UInt64 = 0
  private static let pendingCapacity = VideoContract.previewPendingLimit
  private struct QueuedSample {
    let sample: CMSampleBuffer
    let generation: UInt64
#if CAPTURE_LIFECYCLE_TESTS
    let queuedAt = ProcessInfo.processInfo.systemUptime
#endif
  }
  private var pending = [QueuedSample?](repeating: nil, count: pendingCapacity)
  private var pendingHead = 0
  private var pendingCount = 0
  private var scheduled = false
  private var visible = false
  private var metricsPending = false
  private var metricsRequestedAt = -Double.infinity
#if CAPTURE_LIFECYCLE_TESTS
  // Bare command-line XCTest hosts may be classified as occluded by AppKit.
  // This exists only in test builds; production always follows native visibility.
  private var renderWhenUnattached = false
  private var readinessStartedAt = 0.0
  private var enqueuedTimes: [CMTime] = []
#endif
  // Owned only by the preview queue; at most one readiness callback is armed.
  private var requesting = false
  private var diagnostics = Diagnostics()

  @MainActor init() {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = NSColor.black.cgColor
    displayLayer = layer
    videoRenderer = layer.sampleBufferRenderer
  }

#if CAPTURE_LIFECYCLE_TESTS
  @MainActor convenience init(renderWhenUnattached: Bool) {
    self.init()
    self.renderWhenUnattached = renderWhenUnattached
    visible = renderWhenUnattached
  }

  func setVisibilityForTesting(_ value: Bool) { setVisible(value) }
  func enqueuedTimesForTesting() -> [CMTime] { lock.withLock { enqueuedTimes } }
#endif

  deinit {
    // Every executing queue/callback method holds self strongly. Deinit can
    // therefore stop the remaining weak callback without concurrent rendering.
    videoRenderer.stopRequestingMediaData()
  }

  // Capture can check demand without visiting AppKit or dispatching to the main
  // thread for every frame. The owning view publishes visibility on UI events.
  var isVisible: Bool { lock.withLock { visible } }

  // A fixed ring absorbs short native display/host scheduling stalls. It holds
  // only sample references, plus at most one executing sample/work item. On
  // overflow, evict the oldest queued image so latency cannot grow unbounded.
  func enqueue(_ sample: CMSampleBuffer) {
    lock.withLock {
      guard visible else { return }
      diagnostics.received &+= 1
      if pendingCount == Self.pendingCapacity {
        _ = popPendingLocked()
        diagnostics.replaced &+= 1
      }
      let index = (pendingHead + pendingCount) % Self.pendingCapacity
      pending[index] = QueuedSample(sample: sample, generation: generation)
      pendingCount += 1
      guard !scheduled else { return }
      scheduled = true
      queue.async { [weak self] in self?.drainOne() }
    }
  }

  func flush() {
    lock.withLock {
      flushLocked(resetDiagnostics: true)
    }
  }

  fileprivate func publishViewVisibility(_ value: Bool) {
#if CAPTURE_LIFECYCLE_TESTS
    guard !renderWhenUnattached else { return }
#endif
    setVisible(value)
  }

  private func setVisible(_ value: Bool) {
    lock.withLock {
      guard visible != value else { return }
      visible = value
      if !value { flushLocked(resetDiagnostics: false) }
    }
  }

  // Caller holds lock so invalidation/flush is ordered before a reappearing
  // view's first enqueue. Hidden views release pending/native images promptly.
  private func flushLocked(resetDiagnostics: Bool) {
    generation &+= 1
    for index in pending.indices { pending[index] = nil }
    pendingHead = 0
    pendingCount = 0
    if resetDiagnostics {
      let lifetime = (diagnostics.rendererFrames, diagnostics.rendererDropped, diagnostics.rendererCorrupted)
      diagnostics = Diagnostics()
#if CAPTURE_LIFECYCLE_TESTS
      enqueuedTimes.removeAll(keepingCapacity: true)
#endif
      (diagnostics.rendererFrames, diagnostics.rendererDropped, diagnostics.rendererCorrupted) = lifetime
    }
    // Queue insertion under the same lock orders the flush before any new
    // generation's enqueue. Stale work cannot redisplay a stopped frame.
    queue.async { [weak self] in
      guard let self else { return }
      let wasRequesting = self.requesting
      if self.requesting {
        self.videoRenderer.stopRequestingMediaData()
        self.requesting = false
      }
      self.videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
      self.stager = CameraFrameStager()
      if wasRequesting {
        self.lock.withLock {
          if self.pendingCount == 0 { self.scheduled = false }
          else { self.queue.async { [weak self] in self?.drainOne() } }
        }
      }
    }
  }

  func diagnosticsSnapshot() -> Diagnostics {
    lock.withLock {
      var result = diagnostics
      result.pending = pendingCount
      return result
    }
  }

  @MainActor func makeView() -> VideoPreviewView {
    VideoPreviewView(renderer: self, displayLayer: displayLayer)
  }

  // Standalone borrowed-input users can pay bounded IOSurface/Metal startup
  // costs before their first timed frame. CaptureController normally prepares
  // its one shared transport stager, and previews receive those IOSurfaces.
  func prepareForInput(width: Int, height: Int, pixelFormat: OSType,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let token = lock.withLock { generation }
    queue.async { [weak self] in
      guard let self, self.lock.withLock({ self.visible && token == self.generation }) else {
        completion(.success(()))
        return
      }
      do {
        try self.stager.prepare(width: width, height: height, pixelFormat: pixelFormat)
        completion(.success(()))
      } catch { completion(.failure(error)) }
    }
  }

  func loadPerformanceMetrics(_ completion: @escaping @Sendable (AVVideoPerformanceMetrics?) -> Void) {
    videoRenderer.loadVideoPerformanceMetrics(completionHandler: completion)
  }

  func refreshPerformanceMetrics() {
    let now = ProcessInfo.processInfo.systemUptime
    let token = lock.withLock { () -> UInt64? in
      guard visible, !metricsPending, now - metricsRequestedAt >= 1 else { return nil }
      metricsPending = true
      metricsRequestedAt = now
      return generation
    }
    guard let token else { return }
    videoRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
      guard let self else { return }
      self.lock.withLock {
        self.metricsPending = false
        guard token == self.generation, let metrics else { return }
        self.diagnostics.rendererFrames = UInt64(max(0, metrics.totalNumberOfFrames))
        self.diagnostics.rendererDropped = UInt64(max(0, metrics.numberOfDroppedFrames))
        self.diagnostics.rendererCorrupted = UInt64(max(0, metrics.numberOfCorruptedFrames))
      }
    }
  }

  // Caller holds lock. A ring avoids shifting/retaining an array every frame.
  private func popPendingLocked() -> QueuedSample? {
    guard pendingCount > 0 else { return nil }
    let next = pending[pendingHead]
    pending[pendingHead] = nil
    pendingHead = (pendingHead + 1) % Self.pendingCapacity
    pendingCount -= 1
    return next
  }

  private func drainOne() {
    let next = lock.withLock { () -> QueuedSample? in
      let next = popPendingLocked()
#if CAPTURE_LIFECYCLE_TESTS
      if let next {
        diagnostics.maxQueueWaitMS = max(diagnostics.maxQueueWaitMS,
          (ProcessInfo.processInfo.systemUptime - next.queuedAt) * 1000)
      }
#endif
      return next
    }
    if let next, !render(next) { return }
    lock.withLock {
      if pendingCount == 0 { scheduled = false }
      else { queue.async { [weak self] in self?.drainOne() } }
    }
  }

  // false means a readiness callback owns resumption; never spin on readiness.
  private func render(_ queued: QueuedSample) -> Bool {
    let sample = queued.sample, token = queued.generation
    guard lock.withLock({ visible && token == generation }) else { return true }
    if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
      let error = videoRenderer.error?.localizedDescription ?? "Preview renderer required a reset."
      lock.withLock { diagnostics.failed &+= 1; diagnostics.lastError = error }
      videoRenderer.flush()
    }
    guard videoRenderer.isReadyForMoreMediaData else {
      let current = lock.withLock { () -> Bool in
        guard visible && token == generation else { return false }
        diagnostics.backPressure &+= 1
        if pendingCount < Self.pendingCapacity {
          pendingHead = (pendingHead + Self.pendingCapacity - 1) % Self.pendingCapacity
          pending[pendingHead] = queued
          pendingCount += 1
        } else {
          diagnostics.replaced &+= 1
        }
        return true
      }
      guard current else { return true }
      if !requesting {
        requesting = true
#if CAPTURE_LIFECYCLE_TESTS
        readinessStartedAt = ProcessInfo.processInfo.systemUptime
#endif
        videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
          guard let self, self.requesting else { return }
#if CAPTURE_LIFECYCLE_TESTS
          self.lock.withLock {
            self.diagnostics.maxReadinessWaitMS = max(self.diagnostics.maxReadinessWaitMS,
              (ProcessInfo.processInfo.systemUptime - self.readinessStartedAt) * 1000)
          }
#endif
          self.videoRenderer.stopRequestingMediaData()
          self.requesting = false
          self.drainOne()
        }
      }
      return false
    }
    do {
      // Only borrowed, non-IOSurface capture buffers require staging. This is
      // a bounded bit-exact copy, preserving the selected output pixel format.
#if CAPTURE_LIFECYCLE_TESTS
      let stagingStarted = ProcessInfo.processInfo.systemUptime
      let stagingCPUStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
#endif
      guard let staged = try stager.stage(sample) else {
        lock.withLock { diagnostics.stagingDrops &+= 1 }
        return true
      }
#if CAPTURE_LIFECYCLE_TESTS
      let stagingMS = (ProcessInfo.processInfo.systemUptime - stagingStarted) * 1000
      let stagingCPUMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - stagingCPUStarted) / 1_000_000
      lock.withLock {
        if diagnostics.stagingFrames == 0 {
          diagnostics.firstStagingMS = stagingMS
          diagnostics.firstStagingCPUMS = stagingCPUMS
          diagnostics.firstRawCopy = stager.lastRawCopyTiming
        }
        diagnostics.maxStagingCPUMS = max(diagnostics.maxStagingCPUMS, stagingCPUMS)
        diagnostics.maxStagingMS = max(diagnostics.maxStagingMS, stagingMS)
        diagnostics.stagingTotalMS += stagingMS
        diagnostics.stagingFrames += 1
      }
#endif
      guard let image = CMSampleBufferGetImageBuffer(staged),
        let format = CMSampleBufferGetFormatDescription(staged), CMSampleBufferDataIsReady(staged) else {
        throw VideoError.message("Preview sample has no ready video image.")
      }
      var timing = CMSampleTimingInfo()
      var status = CMSampleBufferGetSampleTimingInfo(staged, at: 0, timingInfoOut: &timing)
      guard status == noErr else { throw VideoError.message("Preview sample timing is unavailable (\(status)).") }
      var preview: CMSampleBuffer?
      status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &preview)
      guard status == noErr, let preview else { throw VideoError.message("Cannot create preview sample (\(status)).") }
      // Independent sample attachments leave the camera's original sample and
      // media timing untouched. A live preview always shows the newest image.
      let attachments = CMSampleBufferGetSampleAttachmentsArray(preview, createIfNecessary: true)! as NSArray
      let attachment = unsafeBitCast(attachments[0] as AnyObject, to: CFMutableDictionary.self)
      CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      lock.withLock {
        guard visible && token == generation else { return }
        videoRenderer.enqueue(preview)
        diagnostics.enqueued &+= 1
#if CAPTURE_LIFECYCLE_TESTS
        if enqueuedTimes.count == 64 { enqueuedTimes.removeFirst() }
        enqueuedTimes.append(CMSampleBufferGetPresentationTimeStamp(preview))
#endif
      }
    } catch {
      lock.withLock { diagnostics.failed &+= 1; diagnostics.lastError = error.localizedDescription }
    }
    return true
  }
}

struct VideoPreview: NSViewRepresentable {
  let renderer: VideoPreviewRenderer

  func makeNSView(context: Context) -> VideoPreviewView {
    renderer.makeView()
  }

  func updateNSView(_ nsView: VideoPreviewView, context: Context) {}
}

@MainActor final class VideoPreviewView: NSView {
  private let renderer: VideoPreviewRenderer
  private let displayLayer: AVSampleBufferDisplayLayer

  init(renderer: VideoPreviewRenderer, displayLayer: AVSampleBufferDisplayLayer) {
    self.renderer = renderer
    self.displayLayer = displayLayer
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) { nil }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.willCloseNotification, object: window)
    }
    publishVisibility()
  }

  override func viewDidHide() {
    super.viewDidHide()
    publishVisibility()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    publishVisibility()
  }

  @objc private func windowVisibilityChanged(_ notification: Notification) {
    if notification.name == NSWindow.willCloseNotification { renderer.publishViewVisibility(false) }
    else { publishVisibility() }
  }

  private func publishVisibility() {
    renderer.publishViewVisibility(window?.isVisible == true && window?.occlusionState.contains(.visible) == true
      && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
    publishVisibility()
  }
}

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
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
  }

  @MainActor fileprivate let displayLayer: AVSampleBufferDisplayLayer
  private let videoRenderer: AVSampleBufferVideoRenderer
  private let queue = DispatchQueue(label: "org.ultrastudiolut.preview", qos: .userInteractive)
  private let lock = NSLock()
  private var stager = CameraFrameStager()
  private var generation: UInt64 = 0
  private var pending: (CMSampleBuffer, UInt64)?
  private var scheduled = false
  private var visible = false
  private var metricsPending = false
  private var metricsRequestedAt = -Double.infinity
#if CAPTURE_LIFECYCLE_TESTS
  // Bare command-line XCTest hosts may be classified as occluded by AppKit.
  // This exists only in test builds; production always follows native visibility.
  private var renderWhenUnattached = false
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
#endif

  deinit {
    // Every executing queue/callback method holds self strongly. Deinit can
    // therefore stop the remaining weak callback without concurrent rendering.
    videoRenderer.stopRequestingMediaData()
  }

  // Capture can check demand without visiting AppKit or dispatching to the main
  // thread for every frame. The owning view publishes visibility on UI events.
  var isVisible: Bool { lock.withLock { visible } }

  // One pending sample and one scheduled work item are retained, even if the
  // main thread or native display becomes busy. New frames replace stale ones.
  func enqueue(_ sample: CMSampleBuffer) {
    lock.withLock {
      guard visible else { return }
      diagnostics.received &+= 1
      if pending != nil { diagnostics.replaced &+= 1 }
      pending = (sample, generation)
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
    pending = nil
    if resetDiagnostics {
      let lifetime = (diagnostics.rendererFrames, diagnostics.rendererDropped, diagnostics.rendererCorrupted)
      diagnostics = Diagnostics()
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
          if self.pending == nil { self.scheduled = false }
          else { self.queue.async { [weak self] in self?.drainOne() } }
        }
      }
    }
  }

  func diagnosticsSnapshot() -> Diagnostics {
    lock.withLock {
      var result = diagnostics
      result.pending = pending == nil ? 0 : 1
      return result
    }
  }

  @MainActor func makeView() -> VideoPreviewView {
    VideoPreviewView(renderer: self, displayLayer: displayLayer)
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

  private func drainOne() {
    let next = lock.withLock { () -> (CMSampleBuffer, UInt64)? in
      let next = pending
      pending = nil
      return next
    }
    if let (sample, token) = next, !render(sample, token: token) { return }
    lock.withLock {
      if pending == nil { scheduled = false }
      else { queue.async { [weak self] in self?.drainOne() } }
    }
  }

  // false means a readiness callback owns resumption; never spin on readiness.
  private func render(_ sample: CMSampleBuffer, token: UInt64) -> Bool {
    guard lock.withLock({ visible && token == generation }) else { return true }
    if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
      let error = videoRenderer.error?.localizedDescription ?? "Preview renderer required a reset."
      lock.withLock { diagnostics.failed &+= 1; diagnostics.lastError = error }
      videoRenderer.flush()
    }
    guard videoRenderer.isReadyForMoreMediaData else {
      lock.withLock {
        diagnostics.backPressure &+= 1
        if token == generation {
          if pending == nil { pending = (sample, token) }
          else { diagnostics.replaced &+= 1 }
        }
      }
      if !requesting {
        requesting = true
        videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
          guard let self, self.requesting else { return }
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
      guard let staged = try stager.stage(sample) else {
        lock.withLock { diagnostics.stagingDrops &+= 1 }
        return true
      }
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

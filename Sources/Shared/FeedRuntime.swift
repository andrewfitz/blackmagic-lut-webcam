import CoreVideo
import Foundation

/// The lifecycle owned by one configured feed. Capture and camera transport
/// are deliberately outside this contract for now; they advance this state
/// through the coordinator while retaining their existing single-feed path.
enum FeedSessionState: Equatable, Sendable {
  case idle
  case running
  case unavailable(String)
  case failed(String)
}

/// Runtime state and output ownership for one feed descriptor.
///
/// A session owns its fan-out instance so stopping one feed drains only that
/// feed's pending leases. The capture implementation can publish processed
/// frames here when the descriptor-driven output routes are integrated.
@MainActor
final class FeedSession: Identifiable {
  let id: FeedID
  private(set) var descriptor: FeedDescriptor
  private(set) var state: FeedSessionState = .idle
  private(set) var generation: UInt64 = 0
  let frameFanOut: FrameFanOut<CVPixelBuffer>

  var isRunning: Bool { state == .running }

  init(descriptor: FeedDescriptor,
       frameFanOut: FrameFanOut<CVPixelBuffer> = FrameFanOut()) {
    id = descriptor.id
    self.descriptor = descriptor
    self.frameFanOut = frameFanOut
  }

  func update(descriptor: FeedDescriptor) {
    guard descriptor.id == id else { return }
    self.descriptor = descriptor
    if !descriptor.enabled, isRunning { stop() }
  }

  /// Starts a configured feed and returns false when the descriptor is
  /// disabled or the session is already active.
  @discardableResult
  func start() -> Bool {
    guard descriptor.enabled else {
      state = .unavailable("Feed is disabled")
      return false
    }
    guard !isRunning else { return false }
    generation &+= 1
    state = .running
    return true
  }

  /// Stops this feed and drains queued route leases while leaving route
  /// registration intact for a later start.
  func stop() {
    guard state != .idle else { return }
    generation &+= 1
    frameFanOut.drain()
    state = .idle
  }

  func fail(_ message: String) {
    generation &+= 1
    frameFanOut.drain()
    state = .failed(message)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>) -> FrameFanOutReport {
    guard isRunning else {
      return FrameFanOutReport(outcomes: [:], routerClosed: false)
    }
    return frameFanOut.publish(frame)
  }

  func addRoute(id: String, capacity: Int,
                policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try frameFanOut.addRoute(id: id, capacity: capacity, policy: policy)
  }

  func removeRoute(_ route: FrameRoute<CVPixelBuffer>) {
    route.cancel()
  }
}

/// Main-actor collection of stable feed descriptors, runtime sessions, and
/// capture owners. Persisted ordering remains the source of truth for the
/// collection; sessions and controllers are created only for descriptors that
/// are accessed. Each controller owns an independent DeckLink backend.
@MainActor
final class FeedCoordinator {
  private(set) var descriptors: [FeedDescriptor]
  private(set) var selectedFeedID: FeedID
  private(set) var outputMode: FeedOutputMode
  private(set) var switcher: SwitcherSettings
  private(set) var virtualCameraRegistryVersion: Int
  private var sessions: [FeedID: FeedSession] = [:]
  let capturePool: FeedCapturePool

  init(snapshot: AppSettingsSnapshot = AppSettingsSnapshot(),
       capturePool: FeedCapturePool = FeedCapturePool()) {
    let safe = snapshot.validated() ?? AppSettingsSnapshot()
    descriptors = safe.feeds
    selectedFeedID = safe.selectedFeedID
    outputMode = safe.outputMode
    switcher = safe.switcher
    virtualCameraRegistryVersion = safe.virtualCameraRegistryVersion
    self.capturePool = capturePool
  }

  var selectedDescriptor: FeedDescriptor {
    descriptors.first(where: { $0.id == selectedFeedID }) ?? descriptors[0]
  }

  var orderedSessions: [FeedSession] {
    descriptors.filter(\.enabled).compactMap { sessions[$0.id] }
  }

  var selectedSession: FeedSession { session(for: selectedFeedID) }

  /// Stable capture owner for one feed.  Calling this for one feed never
  /// changes or reuses another feed's UDLBackend.
  func capture(for id: FeedID) -> CaptureController {
    capturePool.controller(for: id)
  }

  /// Lazily creates a session while preserving descriptor ordering.
  func session(for id: FeedID) -> FeedSession {
    if let session = sessions[id] { return session }
    let descriptor = descriptors.first(where: { $0.id == id }) ?? FeedDescriptor(id: id)
    if !descriptors.contains(where: { $0.id == id }) { descriptors.append(descriptor) }
    let session = FeedSession(descriptor: descriptor)
    sessions[id] = session
    return session
  }

  @discardableResult
  func select(_ id: FeedID) -> Bool {
    guard descriptors.contains(where: { $0.id == id }) else { return false }
    selectedFeedID = id
    if switcher.selectedFeedID == nil { switcher.selectedFeedID = id }
    return true
  }

  func update(_ descriptor: FeedDescriptor) {
    guard let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) else {
      descriptors.append(descriptor)
      return
    }
    descriptors[index] = descriptor
    sessions[descriptor.id]?.update(descriptor: descriptor)
  }

  @discardableResult
  func add(name: String? = nil) -> FeedID {
    var id = FeedID(uuid: UUID())
    while descriptors.contains(where: { $0.id == id }) { id = FeedID(uuid: UUID()) }
    let descriptor = FeedDescriptor(id: id, name: name ?? "Feed \(descriptors.count + 1)")
    descriptors.append(descriptor)
    return id
  }

  /// Removes an idle feed. A running feed remains configured until its owner
  /// explicitly stops it, preventing a dangling route or camera client.
  @discardableResult
  func remove(_ id: FeedID) -> Bool {
    guard descriptors.count > 1, let index = descriptors.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard sessions[id]?.isRunning != true else { return false }
    guard capturePool.remove(id) else { return false }
    sessions.removeValue(forKey: id)?.stop()
    descriptors.remove(at: index)
    if selectedFeedID == id { selectedFeedID = descriptors[0].id }
    if switcher.selectedFeedID == id { switcher.selectedFeedID = selectedFeedID }
    return true
  }

  @discardableResult
  func start(_ id: FeedID) -> Bool { session(for: id).start() }

  func stop(_ id: FeedID) {
    capturePool.stop(id)
    session(for: id).stop()
  }

  /// Starts the session and its independent native capture owner as one
  /// operation. The native controller reports asynchronous signal failures in
  /// its update stream, matching the established single-feed behavior.
  @discardableResult
  func startCapture(feedID: FeedID, deviceID: String, configuration: PipelineConfiguration,
                    pipelineEnabled: Bool = true, previewEnabled: Bool = true) -> Bool {
    guard start(feedID) else { return false }
    capture(for: feedID).start(feedID: feedID, deviceID: deviceID,
      configuration: configuration, pipelineEnabled: pipelineEnabled,
      previewEnabled: previewEnabled)
    return true
  }

  func stopCapture(feedID: FeedID) {
    capturePool.stop(feedID)
    session(for: feedID).stop()
  }

  func reconfigureCapture(feedID: FeedID, configuration: PipelineConfiguration,
                          pipelineEnabled: Bool) {
    capture(for: feedID).reconfigure(configuration: configuration, pipelineEnabled: pipelineEnabled)
  }

  func setPreviewEnabled(feedID: FeedID, enabled: Bool) {
    capture(for: feedID).setPreviewEnabled(enabled)
  }

  func setRecordingCallbacks(feedID: FeedID,
                             callbacks: SourceRecordingCallbackAdapter.Callbacks?) {
    capture(for: feedID).setRecordingCallbacks(feedID: feedID, callbacks: callbacks)
  }

  func addOutputRoute(feedID: FeedID, routeID: String, capacity: Int,
                      policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try session(for: feedID).addRoute(id: routeID, capacity: capacity, policy: policy)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>, to feedID: FeedID)
    -> FrameFanOutReport {
    session(for: feedID).publish(frame)
  }

  func setOutputMode(_ mode: FeedOutputMode) { outputMode = mode }

  func setSwitcher(_ settings: SwitcherSettings) {
    switcher = settings
    if let selected = settings.selectedFeedID, descriptors.contains(where: { $0.id == selected }) {
      return
    }
    switcher.selectedFeedID = selectedFeedID
  }

  var snapshot: AppSettingsSnapshot {
    AppSettingsSnapshot(feeds: descriptors, selectedFeedID: selectedFeedID,
      outputMode: outputMode, switcher: switcher,
      virtualCameraRegistryVersion: virtualCameraRegistryVersion)
  }
}

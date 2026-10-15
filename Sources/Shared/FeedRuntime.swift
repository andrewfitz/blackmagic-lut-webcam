import CoreMedia
import CoreVideo
import Foundation

/// The result of routing one processed frame through the Program output.
/// The scheduler decision remains available to diagnostics while the route
/// itself owns the bounded queue and retains the frame for its consumers.
struct ProgramRouteResult: @unchecked Sendable {
  let decision: ProgramFrameDecision<FeedID>
  let fanOut: FrameFanOutReport
}

/// Queue-owned Program output shared by all configured feeds. A source frame
/// is evaluated by `SwitcherCoordinator` first; only the selected source (or
/// the target at a valid cut boundary) is published to Program consumers.
@MainActor
final class ProgramOutputRoute {
  private(set) var switcher: SwitcherCoordinator
  let fanOut: FrameFanOut<CVPixelBuffer>

  init(settings: SwitcherSettings = .init(), feedIDs: [FeedID],
       routeLabel: String = "org.ultrastudiolut.program-output") {
    switcher = SwitcherCoordinator(settings: settings, feedIDs: feedIDs)
    fanOut = FrameFanOut(label: routeLabel)
  }

  var selectedFeedID: FeedID? { switcher.selectedFeedID }
  var pendingFeedID: FeedID? { switcher.pendingCut }
  var hasPendingCut: Bool { switcher.hasPendingCut }

  func updateFeeds(_ feedIDs: [FeedID]) {
    // Descriptor edits (name, LUT, format) arrive through the same coordinator
    // as topology edits. Do not reset the Program clock or drain a live queue
    // when the ordered feed identity set is unchanged.
    if switcher.feedIDs == feedIDs { return }
    let valid = Set(feedIDs)
    let selected = switcher.selectedFeedID.flatMap { valid.contains($0) ? $0 : nil }
    var settings = switcher.settings
    settings.selectedFeedID = selected ?? feedIDs.first
    // A topology change invalidates every queued source frame. Keeping those
    // leases would let a removed feed leak into the next Program segment and
    // would retain pixel buffers until the consumer happened to dequeue them.
    fanOut.drain()
    switcher = SwitcherCoordinator(settings: settings, feedIDs: feedIDs)
  }

  /// Updates switch policy on the same coordinator that ingests Program
  /// frames. FeedCoordinator mirrors this value for persistence/UI, but must
  /// never maintain a second scheduler with independent pending cuts.
  func updateSettings(_ settings: SwitcherSettings) {
    switcher.updateSettings(settings)
  }

  @discardableResult
  func requestCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    switcher.requestManualCut(to: feedID)
  }

  @discardableResult
  func evaluate(at mediaTime: CMTime) -> SwitcherEvaluation {
    switcher.evaluate(at: mediaTime)
  }

  /// Routes a processed frame without copying or re-running effects. The
  /// caller retains ownership of `frame`; every accepted Program consumer gets
  /// its own lease from `fanOut`.
  @discardableResult
  func ingest(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>) -> ProgramRouteResult {
    let metadata = frame.metadata
    let source = ProgramSourceFrame(sourceID: feedID,
      sourceTime: metadata.presentationTime, duration: metadata.duration)
    let decision = switcher.ingest(source)
    let report: FrameFanOutReport
    switch decision {
    case let .accepted(mapped), let .cutApplied(mapped, _):
      // The scheduler maps each source clock onto one monotonic Program clock.
      // Wrap the existing pixel buffer with mapped metadata; this intentionally
      // performs no pixel copy or colour conversion before the CMIO bridge.
      let mappedMetadata = ProcessedFrameMetadata(
        presentationTime: mapped.programTime,
        duration: mapped.programDuration,
        width: metadata.width,
        height: metadata.height,
        pixelFormat: metadata.pixelFormat)
      let programFrame = ProcessedFrame(payload: frame.payload, metadata: mappedMetadata)
      report = fanOut.publish(programFrame)
    case .skipped:
      report = FrameFanOutReport(outcomes: [:])
    }
    return ProgramRouteResult(decision: decision, fanOut: report)
  }

  func addConsumerRoute(id: String = "program-camera", capacity: Int = 12,
                        policy: FrameQueueOverflowPolicy = .dropOldest)
    throws -> FrameRoute<CVPixelBuffer> {
    try fanOut.addRoute(id: id, capacity: capacity, policy: policy)
  }

  func reset() { switcher.reset() }
}

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
  private(set) var switcherCoordinator: SwitcherCoordinator
  private(set) var virtualCameraRegistrySnapshot: VirtualCameraRegistrySnapshot
  private let registryStore: VirtualCameraRegistryStore?
  private var sessions: [FeedID: FeedSession] = [:]
  let capturePool: FeedCapturePool
  let programOutput: ProgramOutputRoute
  private var demandCoordinator: RouteDemandCoordinator
  private var programConsumerActive = false

  init(snapshot: AppSettingsSnapshot = AppSettingsSnapshot(),
       capturePool: FeedCapturePool = FeedCapturePool(),
       registryStore: VirtualCameraRegistryStore? = nil) {
    let safe = snapshot.validated() ?? AppSettingsSnapshot()
    descriptors = safe.feeds
    selectedFeedID = safe.selectedFeedID
    outputMode = safe.outputMode
    switcher = safe.switcher
    virtualCameraRegistryVersion = safe.virtualCameraRegistryVersion
    switcherCoordinator = SwitcherCoordinator(settings: safe.switcher, feeds: safe.feeds)
    switcher = switcherCoordinator.settings
    programOutput = ProgramOutputRoute(settings: safe.switcher,
      feedIDs: safe.feeds.filter(\.enabled).map(\.id))
    demandCoordinator = RouteDemandCoordinator()
    self.registryStore = registryStore
    self.capturePool = capturePool
    let initialDevices = Self.registryDevices(for: safe.outputMode, feeds: safe.feeds)
    let stored = registryStore?.load()
    let generation = max(stored?.generation ?? 0, UInt64(max(1, safe.virtualCameraRegistryVersion)))
    virtualCameraRegistrySnapshot = VirtualCameraRegistrySnapshot(generation: generation,
      devices: initialDevices)
    if registryStore != nil { publishVirtualCameraRegistry() }
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
    if switcher.selectedFeedID == nil {
      switcher.selectedFeedID = id
      programOutput.updateSettings(switcher)
      syncSwitcherMirror()
    }
    return true
  }

  func update(_ descriptor: FeedDescriptor) {
    guard let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) else {
      descriptors.append(descriptor)
      programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
      syncSwitcherMirror()
      publishVirtualCameraRegistry()
      return
    }
    descriptors[index] = descriptor
    sessions[descriptor.id]?.update(descriptor: descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    syncSwitcherMirror()
    publishVirtualCameraRegistry()
  }

  @discardableResult
  func add(name: String? = nil) -> FeedID {
    var id = FeedID(uuid: UUID())
    while descriptors.contains(where: { $0.id == id }) { id = FeedID(uuid: UUID()) }
    let descriptor = FeedDescriptor(id: id, name: name ?? "Feed \(descriptors.count + 1)")
    descriptors.append(descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    syncSwitcherMirror()
    publishVirtualCameraRegistry()
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
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    syncSwitcherMirror()
    if programConsumerActive {
      demandCoordinator.selectProgram(feedID: programOutput.selectedFeedID?.rawValue)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
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
    let feedSession = session(for: feedID)
    let report = feedSession.publish(frame)
    if feedSession.isRunning { _ = ingestProgramFrame(feedID: feedID, frame: frame) }
    return report
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard outputMode != mode else { return }
    outputMode = mode
    // Rebuild the Program scheduler at the mode boundary so its selected
    // source and timestamp mapper start from the persisted feed topology.
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    syncSwitcherMirror()
    publishVirtualCameraRegistry()
  }

  func setSwitcher(_ settings: SwitcherSettings) {
    var normalized = settings
    let requested = settings.selectedFeedID.flatMap { candidate in
      descriptors.contains(where: { $0.id == candidate && $0.enabled }) ? candidate : nil
    } ?? selectedFeedID
    normalized.selectedFeedID = requested
    programOutput.updateSettings(normalized)
    if outputMode == .program, programOutput.selectedFeedID != requested {
      _ = programOutput.requestCut(to: requested)
    }
    syncSwitcherMirror()
    publishVirtualCameraRegistry()
  }

  /// Requests a frame-boundary Program cut. The selected feed is persisted
  /// after the target frame is acknowledged by `ingestProgramFrame`.
  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    let result = programOutput.requestCut(to: feedID)
    syncSwitcherMirror()
    return result
  }

  @discardableResult
  func evaluateSwitcher(at mediaTime: CMTime) -> SwitcherEvaluation {
    let result = programOutput.evaluate(at: mediaTime)
    syncSwitcherMirror()
    return result
  }

  /// Publishes a processed frame to the Program route when Program mode is
  /// active. Separate-camera mode leaves the frame on its feed route only.
  @discardableResult
  func ingestProgramFrame(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>)
    -> ProgramRouteResult? {
    guard outputMode == .program, descriptors.contains(where: { $0.id == feedID && $0.enabled }) else {
      return nil
    }
    let result = programOutput.ingest(feedID: feedID, frame: frame)
    syncSwitcherMirror()
    if case .cutApplied = result.decision {
      selectedFeedID = feedID
      if programConsumerActive {
        demandCoordinator.selectProgram(feedID: feedID.rawValue)
      }
    }
    return result
  }

  @discardableResult
  func addProgramOutputRoute(id: String = "program-camera", capacity: Int = 12,
                             policy: FrameQueueOverflowPolicy = .dropOldest)
    throws -> FrameRoute<CVPixelBuffer> {
    try programOutput.addConsumerRoute(id: id, capacity: capacity, policy: policy)
  }

  /// Ties source demand to the Program camera's consumer lifecycle. The
  /// caller executes returned start/stop transitions against its capture pool.
  @discardableResult
  func setProgramConsumer(_ active: Bool, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    programConsumerActive = active
    demandCoordinator.selectProgram(feedID: active ? (switcherCoordinator.selectedFeedID?.rawValue) : nil,
      at: time)
    return demandCoordinator.drainTransitions()
  }

  @discardableResult
  func setDedicatedCameraConsumer(feedID: FeedID, active: Bool,
                                  ownerID: String? = nil, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    if active {
      _ = demandCoordinator.acquire(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    } else {
      _ = demandCoordinator.release(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    }
    return demandCoordinator.drainTransitions()
  }

  @discardableResult
  func advanceDemand(to time: TimeInterval) -> [SourceDemandTransition] {
    demandCoordinator.advance(to: time)
  }

  var activeDemandFeedIDs: Set<String> { demandCoordinator.activeFeedIDs }

  /// ProgramOutputRoute owns the live scheduler. Keep the public mirror used
  /// by persistence and diagnostics synchronized after every route mutation.
  private func syncSwitcherMirror() {
    switcherCoordinator = programOutput.switcher
    switcher = switcherCoordinator.settings
  }

  /// Complete registry state published to the camera extension. Separate
  /// mode exposes one stable device per enabled feed; Program mode exposes one
  /// Program device while feed captures remain internal sources.
  var virtualCameraDescriptors: [VirtualCameraDescriptor] {
    Self.registryDevices(for: outputMode, feeds: descriptors)
  }

  var snapshot: AppSettingsSnapshot {
    AppSettingsSnapshot(feeds: descriptors, selectedFeedID: selectedFeedID,
      outputMode: outputMode, switcher: switcher,
      virtualCameraRegistryVersion: virtualCameraRegistryVersion)
  }

  @discardableResult
  private func publishVirtualCameraRegistry() -> Bool {
    let devices = virtualCameraDescriptors
    let next: VirtualCameraRegistrySnapshot
    if let current = registryStore?.load() {
      next = current.advancing(to: devices)
    } else {
      let generation = max(virtualCameraRegistrySnapshot.generation + 1, 1)
      next = VirtualCameraRegistrySnapshot(generation: generation, devices: devices)
    }
    virtualCameraRegistrySnapshot = next
    virtualCameraRegistryVersion = Int(min(next.generation, UInt64(Int.max)))
    guard let registryStore else { return true }
    do {
      try registryStore.save(next)
      return true
    } catch {
      return false
    }
  }

  private static func registryDevices(for mode: FeedOutputMode,
                                      feeds: [FeedDescriptor]) -> [VirtualCameraDescriptor] {
    switch mode {
    case .separateCameras:
      return feeds.filter(\.enabled).map { feed in
        VirtualCameraDescriptor.feed(feedID: feed.id.rawValue, displayName: "UltraStudio LUT · \(feed.name)")
      }
    case .program:
      return [VirtualCameraDescriptor.program()]
    }
  }
}

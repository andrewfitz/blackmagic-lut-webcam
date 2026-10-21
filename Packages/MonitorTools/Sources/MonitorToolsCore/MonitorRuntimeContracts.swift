import Foundation

public struct MonitorFrameStamp: Hashable, Codable, Sendable {
  public var target: MonitorTargetID
  public var generation: UInt64
  public var sequence: UInt64
  public var sourcePTS: Double
  public var hostTime: Double
  public var configurationRevision: UInt64
  public var processingRevision: UInt64
  public init(
    target: MonitorTargetID, generation: UInt64, sequence: UInt64, sourcePTS: Double,
    hostTime: Double, configurationRevision: UInt64, processingRevision: UInt64 = 0
  ) {
    self.target = target
    self.generation = generation
    self.sequence = sequence
    self.sourcePTS = sourcePTS
    self.hostTime = hostTime
    self.configurationRevision = configurationRevision
    self.processingRevision = processingRevision
  }
  public func matches(target: MonitorTargetID, generation: UInt64, configurationRevision: UInt64)
    -> Bool
  {
    self.target == target && self.generation == generation
      && self.configurationRevision == configurationRevision
  }
}
public enum MonitorAvailability: Equatable, Sendable {
  case noSignal, starting, live, paused, stale
  case unsupported(String)
  case degraded(String)
  case failed(String)
}
public struct MonitorDiagnostics: Equatable, Sendable {
  public var offeredFrames: UInt64 = 0
  public var offeredFPS: Double = 0
  public var admittedFPS: Double = 0
  public var pictureFPS: Double = 0
  public var scopeFPS: Double = 0
  public var pictureAge: Double?
  public var scopeAge: Double?
  public var scopeStale = true
  public var softDeadlineStatus: MonitorSoftDeadlineStatus = .unavailable
  public var requestedPictureHz = 60.0
  public var requestedScopeHz = 15
  public var effectiveQuality = MonitorEffectiveQuality()
  public var retiredBytes = 0
  public var admittedFrames: UInt64 = 0
  public var skippedFrames: UInt64 = 0
  public var rejectedResults: UInt64 = 0
  public var retainedBytes: Int = 0
  public var analysisFPS: Double = 0
  public var resultAge: Double?
  public var gpuMilliseconds: Double?
  public var availability: MonitorAvailability = .noSignal
  public init() {}
}
public enum MonitorResourceKind: Sendable {
  case analysis, cleanCopy, cleanPresentation, presentation, frozen
}
public struct MonitorAdmissionSnapshot: Equatable, Sendable {
  public let analysisJobs: Int
  public let cleanCopyJobs: Int
  public let retainedBytes: Int
  public let retiredBytes: Int
  public let reservations: Int
}
/// Shared across sessions and generations. A retired reservation remains charged until release.
public final class MonitorAdmissionLedger: @unchecked Sendable {
  private struct Entry {
    let target: MonitorTargetID
    let generation: UInt64
    let kind: MonitorResourceKind
    var bytes: Int
    var retired: Bool
  }
  private let lock = NSLock()
  private var entries: [UUID: Entry] = [:]
  public let maximumAnalysisJobs: Int
  public let maximumCleanCopyJobs: Int
  public let maximumBytes: Int
  public let cleanReserveBytes: Int
  public init(
    maximumAnalysisJobs: Int = 2, maximumCleanCopyJobs: Int = 1,
    maximumBytes: Int = 256 * 1024 * 1024, cleanReserveBytes: Int = 64 * 1024 * 1024
  ) {
    self.maximumAnalysisJobs = max(0, maximumAnalysisJobs)
    self.maximumCleanCopyJobs = max(0, maximumCleanCopyJobs)
    self.maximumBytes = max(0, maximumBytes)
    self.cleanReserveBytes = min(max(0, cleanReserveBytes), max(0, maximumBytes))
  }
  /// Contention skips work; this method never waits for the lock.
  public func tryAcquire(
    target: MonitorTargetID, generation: UInt64, kind: MonitorResourceKind, bytes: Int
  ) -> MonitorResourceLease? {
    guard bytes >= 0, lock.try() else { return nil }
    defer { lock.unlock() }
    let total = entries.values.reduce(0) { $0 + $1.bytes }
    guard bytes <= maximumBytes - total else { return nil }
    // Existing clean presentation already occupies the reserve. Protect only the
    // non-clean partition, rather than reserving clean capacity a second time.
    if kind != .cleanPresentation {
      let nonClean = entries.values.filter { $0.kind != .cleanPresentation }.reduce(0) { $0 + $1.bytes }
      guard bytes <= maximumBytes - cleanReserveBytes - nonClean else { return nil }
    }
    switch kind {
    case .analysis:
      let active = entries.values.filter { $0.kind == .analysis }
      guard active.count < maximumAnalysisJobs, !active.contains(where: { $0.target == target })
      else { return nil }
    case .cleanCopy:
      let copies = entries.values.filter { $0.kind == .cleanCopy }
      guard copies.count < maximumCleanCopyJobs, !copies.contains(where: { $0.target == target })
      else { return nil }
    case .cleanPresentation: break
    case .presentation, .frozen: break
    }
    let id = UUID()
    entries[id] = Entry(
      target: target, generation: generation, kind: kind, bytes: bytes, retired: false)
    return MonitorResourceLease(ledger: self, id: id)
  }
  /// Atomically reserves the independent copy slot and its owned presentation memory.
  /// The copy lease ends after CPU copying; presentation remains charged while displayed.
  public func tryAcquireClean(target: MonitorTargetID, generation: UInt64, bytes: Int) -> (
    copy: MonitorResourceLease, presentation: MonitorResourceLease
  )? {
    guard bytes >= 0, lock.try() else { return nil }
    defer { lock.unlock() }
    let total = entries.values.reduce(0) { $0 + $1.bytes }
    let copies = entries.values.filter { $0.kind == .cleanCopy }
    guard bytes <= maximumBytes - total, copies.count < maximumCleanCopyJobs,
      !copies.contains(where: { $0.target == target })
    else { return nil }
    let copyID = UUID()
    let presentationID = UUID()
    entries[copyID] = Entry(
      target: target, generation: generation, kind: .cleanCopy, bytes: 0, retired: false)
    entries[presentationID] = Entry(
      target: target, generation: generation, kind: .cleanPresentation, bytes: bytes, retired: false
    )
    return (
      MonitorResourceLease(ledger: self, id: copyID),
      MonitorResourceLease(ledger: self, id: presentationID)
    )
  }
  public func retire(target: MonitorTargetID, generation: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    for key in Array(entries.keys)
    where entries[key]?.target == target && entries[key]?.generation == generation {
      entries[key]?.retired = true
    }
  }
  fileprivate func shrink(_ id: UUID, to bytes: Int) -> Bool {
    guard bytes >= 0 else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[id], bytes <= entry.bytes else { return false }
    entry.bytes = bytes
    entries[id] = entry
    return true
  }
  fileprivate func release(_ id: UUID) {
    lock.lock()
    entries.removeValue(forKey: id)
    lock.unlock()
  }
  public var snapshot: MonitorAdmissionSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return MonitorAdmissionSnapshot(
      analysisJobs: entries.values.filter { $0.kind == .analysis }.count,
      cleanCopyJobs: entries.values.filter { $0.kind == .cleanCopy }.count,
      retainedBytes: entries.values.reduce(0) { $0 + $1.bytes },
      retiredBytes: entries.values.filter(\.retired).reduce(0) { $0 + $1.bytes },
      reservations: entries.count)
  }
}
public final class MonitorResourceLease: @unchecked Sendable {
  private let lock = NSLock()
  private var ledger: MonitorAdmissionLedger?
  private let id: UUID
  fileprivate init(ledger: MonitorAdmissionLedger, id: UUID) {
    self.ledger = ledger
    self.id = id
  }
  /// Replaces a conservative reservation with a smaller verified bound.
  /// Call only once the owner can guarantee future allocations remain within it.
  /// This worker-side operation may briefly lock; capture admission remains try-only.
  @discardableResult
  public func shrink(to bytes: Int) -> Bool {
    guard bytes >= 0 else { return false }
    lock.lock()
    defer { lock.unlock() }
    return ledger?.shrink(id, to: bytes) ?? false
  }
  public func release() {
    lock.lock()
    let owner = ledger
    ledger = nil
    lock.unlock()
    owner?.release(id)
  }
  deinit { release() }
}

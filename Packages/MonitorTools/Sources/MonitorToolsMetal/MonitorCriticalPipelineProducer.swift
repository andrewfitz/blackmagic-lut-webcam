import Foundation
import MonitorToolsCore

/// Capture/recording health metadata. This handle never owns a frame or a GPU resource.
/// Keep it alive with the producer, including while all monitor surfaces are hidden.
public final class MonitorCriticalPipelineProducer: @unchecked Sendable {
  private let registry: MonitorCriticalPipelineRegistry
  private let identity: UUID
  public let target: MonitorTargetID

  fileprivate init(
    registry: MonitorCriticalPipelineRegistry, target: MonitorTargetID, identity: UUID
  ) {
    self.registry = registry
    self.target = target
    self.identity = identity
  }

  /// A contended metadata update is skipped; the producer must never wait for monitoring.
  @discardableResult public func record(
    generation: UInt64, queueAge: Double, processingTime: Double, frameInterval: Double, now: Double
  ) -> Bool {
    registry.record(
      identity: identity, target: target, generation: generation,
      queueAge: queueAge, processingTime: processingTime, frameInterval: frameInterval, now: now)
  }

  /// A stopped producer contributes no global pressure. Only a newer generation can resume it.
  /// This control-path operation updates metadata only; it never waits for GPU completion.
  @discardableResult public func stop(generation: UInt64? = nil) -> Bool {
    registry.stop(identity: identity, target: target, generation: generation)
  }

  deinit { registry.unregister(identity: identity, target: target) }
}

struct MonitorCriticalPipelineState: Sendable {
  let phase: MonitorCriticalPipelinePhase
  var reason: String? {
    switch phase {
    case .nominal: nil
    case .paused: "Analysis paused: output pipeline pressure"
    case .recovering: "Reduced monitoring while output pipeline pressure recovers"
    }
  }
  func cap(_ quality: MonitorEffectiveQuality, requestedScopeHz: Int) -> MonitorEffectiveQuality {
    phase == .nominal
      ? quality : MonitorEffectiveQuality(tier: .reduced, requestedScopeHz: requestedScopeHz)
  }
  func apply(to diagnostics: inout MonitorDiagnostics) {
    guard let reason else { return }
    diagnostics.availability = .degraded(reason)
    diagnostics.effectiveQuality = cap(
      diagnostics.effectiveQuality, requestedScopeHz: diagnostics.requestedScopeHz)
  }
}

/// One entry per authoritative live producer target. Identity checks prevent an older
/// handle's delayed stop/deinit from unregistering its replacement. Monitor-session
/// removal deliberately does not remove producer telemetry.
final class MonitorCriticalPipelineRegistry: @unchecked Sendable {
  private struct Entry {
    var identity: UUID
    var generation: UInt64?
    var active = false
    var stopped = false
    var lastNow: Double?
    var policy = MonitorCriticalPipelinePolicy()
  }
  private let lock = NSLock()
  private var entries: [MonitorTargetID: Entry] = [:]
  private var phase: MonitorCriticalPipelinePhase = .nominal

  func makeProducer(target: MonitorTargetID) -> MonitorCriticalPipelineProducer {
    let identity = UUID()
    lock.lock()
    // A replacement controller owns a new capture-generation epoch.
    entries[target] = Entry(identity: identity)
    updatePhase()
    lock.unlock()
    return MonitorCriticalPipelineProducer(registry: self, target: target, identity: identity)
  }

  func snapshot() -> MonitorCriticalPipelineState {
    // Fail closed for new optional analysis while producer metadata is being updated.
    guard lock.try() else { return MonitorCriticalPipelineState(phase: .paused) }
    let value = phase
    lock.unlock()
    return MonitorCriticalPipelineState(phase: value)
  }

  @discardableResult fileprivate func record(
    identity: UUID, target: MonitorTargetID, generation: UInt64, queueAge: Double,
    processingTime: Double, frameInterval: Double, now: Double
  ) -> Bool {
    guard lock.try() else { return false }
    defer { lock.unlock() }
    guard var entry = entries[target], entry.identity == identity,
      entry.generation.map({ generation >= $0 }) ?? true
    else { return false }
    guard
      now.isFinite, now >= 0, queueAge.isFinite, queueAge >= 0,
      processingTime.isFinite, processingTime >= 0, frameInterval.isFinite, frameInterval > 0
    else {
      if entry.generation == generation {
        entry.policy.observe(
          now: now, queueAge: queueAge, processingTime: processingTime,
          frameInterval: frameInterval)
        entries[target] = entry
      }
      return false
    }
    if entry.generation == nil || generation > entry.generation! {
      entry.policy.reset()
      entry.generation = generation
      entry.active = true
      entry.stopped = false
      entry.lastNow = nil
    }
    guard !entry.stopped else { return false }
    guard entry.lastNow.map({ now > $0 }) ?? true else {
      entry.policy.observe(
        now: now, queueAge: queueAge, processingTime: processingTime,
        frameInterval: frameInterval)
      entries[target] = entry
      return false
    }
    entry.lastNow = now
    entry.active = true
    entry.policy.observe(
      now: now, queueAge: queueAge, processingTime: processingTime, frameInterval: frameInterval)
    entries[target] = entry
    updatePhase()
    return true
  }

  @discardableResult fileprivate func stop(
    identity: UUID, target: MonitorTargetID, generation: UInt64?
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[target], entry.identity == identity else { return false }
    if let generation, let latest = entry.generation, generation < latest { return false }
    entry.generation = generation ?? entry.generation ?? 0
    entry.stopped = true
    entry.active = false
    entry.policy.stop()
    entries[target] = entry
    updatePhase()
    return true
  }

  fileprivate func unregister(identity: UUID, target: MonitorTargetID) {
    lock.lock()
    if entries[target]?.identity == identity {
      entries.removeValue(forKey: target)
      updatePhase()
    }
    lock.unlock()
  }

  private func updatePhase() {
    phase = .nominal
    for entry in entries.values where entry.active {
      if entry.policy.phase == .paused {
        phase = .paused
        return
      }
      if entry.policy.phase == .recovering { phase = .recovering }
    }
  }
}

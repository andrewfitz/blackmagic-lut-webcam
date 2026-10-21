import Foundation

public enum MonitorCriticalPipelinePhase: String, Equatable, Sendable {
  case nominal, paused, recovering
}

/// Producer-owned metadata only. The caller suppresses new analysis while paused;
/// neither deadlines nor stop release work already committed to a GPU.
public struct MonitorCriticalPipelinePolicy: Sendable {
  public private(set) var phase: MonitorCriticalPipelinePhase = .nominal
  private var stopped = false
  private var lastSampleTime: Double?
  private var healthyStart: Double?

  public init() {}

  public mutating func reset() {
    self = MonitorCriticalPipelinePolicy()
  }

  /// Remains paused until explicit reset, including if further samples arrive.
  public mutating func stop() {
    stopped = true
    phase = .paused
    healthyStart = nil
  }

  @discardableResult
  public mutating func observe(
    now: Double, queueAge: Double, processingTime: Double, frameInterval: Double
  ) -> MonitorCriticalPipelinePhase {
    guard !stopped else { return phase }
    guard now.isFinite, now >= 0, queueAge.isFinite, queueAge >= 0,
      processingTime.isFinite, processingTime >= 0, frameInterval.isFinite,
      frameInterval > 0, lastSampleTime.map({ now > $0 }) ?? true
    else {
      healthyStart = nil
      return phase
    }
    let previous = lastSampleTime
    lastSampleTime = now
    // Overflow of two otherwise valid finite durations also exceeds the deadline.
    if queueAge + processingTime > frameInterval {
      phase = .paused
      healthyStart = nil
      return phase
    }
    guard phase != .nominal else { return phase }
    let tolerance = max(frameInterval * 1e-6, 1e-9)
    if let previous, now - previous > 2 * frameInterval + tolerance { healthyStart = nil }
    if healthyStart == nil { healthyStart = now }
    guard let start = healthyStart else { return phase }
    let required = phase == .paused ? 1.0 : 5.0
    if now - start >= required {
      if phase == .paused {
        phase = .recovering
        healthyStart = now
      } else {
        phase = .nominal
        healthyStart = nil
      }
    }
    return phase
  }
}

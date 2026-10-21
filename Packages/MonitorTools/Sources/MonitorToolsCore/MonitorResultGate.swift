import Foundation

/// Worker-owned session gate: stream/config changes invalidate results without releasing GPU resources.
public struct MonitorResultGate: Sendable {
  public let target: MonitorTargetID
  public private(set) var generation: UInt64
  public private(set) var processingRevision: UInt64
  public private(set) var configurationRevision: UInt64
  public private(set) var isCancelled = false
  private var lastSequence: UInt64?
  public init(
    target: MonitorTargetID, generation: UInt64 = 0, configurationRevision: UInt64 = 0,
    processingRevision: UInt64 = 0
  ) {
    self.target = target
    self.generation = generation
    self.configurationRevision = configurationRevision
    self.processingRevision = processingRevision
  }
  public mutating func reconfigure(revision: UInt64) {
    configurationRevision = revision
    lastSequence = nil
  }
  public mutating func restart(generation: UInt64) {
    self.generation = generation
    isCancelled = false
    lastSequence = nil
  }
  public mutating func updateProcessing(revision: UInt64) {
    processingRevision = revision
    lastSequence = nil
  }
  public mutating func cancel() { isCancelled = true }
  public mutating func accept(_ stamp: MonitorFrameStamp) -> Bool {
    guard !isCancelled, stamp.processingRevision == processingRevision,
      stamp.matches(
        target: target, generation: generation, configurationRevision: configurationRevision),
      lastSequence.map({ stamp.sequence > $0 }) ?? true
    else { return false }
    lastSequence = stamp.sequence
    return true
  }
}

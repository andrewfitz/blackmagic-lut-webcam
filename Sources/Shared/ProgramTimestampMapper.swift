import CoreMedia

/// A source frame presented to the Program route before it has a Program PTS.
public struct ProgramSourceFrame<SourceID: Hashable> {
  public let sourceID: SourceID
  public let sourceTime: CMTime
  public let duration: CMTime

  public init(sourceID: SourceID, sourceTime: CMTime, duration: CMTime) {
    self.sourceID = sourceID
    self.sourceTime = sourceTime
    self.duration = duration
  }
}

/// A source frame with a timestamp in the single Program timeline.
public struct ProgramMappedFrame<SourceID: Hashable> {
  public let sourceID: SourceID
  public let sourceTime: CMTime
  public let sourceDuration: CMTime
  public let programTime: CMTime
  public let programDuration: CMTime

  public init(sourceID: SourceID, sourceTime: CMTime, sourceDuration: CMTime,
              programTime: CMTime, programDuration: CMTime) {
    self.sourceID = sourceID
    self.sourceTime = sourceTime
    self.sourceDuration = sourceDuration
    self.programTime = programTime
    self.programDuration = programDuration
  }
}

public enum ProgramTimestampMappingError: Error, Equatable {
  case noSelectedSource
  case sourceMismatch
  case invalidSourceTimestamp
  case invalidSourceDuration
  case sourceEpochUnsupported(Int64)
  case sourceTimebaseChanged(expected: Int32, actual: Int32)
  case sourceTimestampRegressed
  case programTimestampNotMonotonic
}

/// Maps each selected source timeline into one monotonic Program timeline.
///
/// A cut leaves the last Program timestamp intact and starts a new source
/// origin. The first accepted frame after the cut therefore begins at the next
/// Program frame boundary even when the new source starts at zero.
public struct ProgramTimestampMapper<SourceID: Hashable> {
  private struct SourceClock {
    let epoch: Int64
    let timescale: Int32
  }

  public let programTimescale: Int32
  public private(set) var selectedSource: SourceID?
  public private(set) var lastProgramTime: CMTime?
  public private(set) var lastProgramDuration: CMTime?

  private var activeClock: SourceClock?
  private var sourceOrigin: CMTime?
  private var programOrigin: CMTime?
  private var lastSourceTime: CMTime?

  public init(programTimescale: Int32 = 60_000, selectedSource: SourceID? = nil) {
    precondition(programTimescale > 0, "Program timescale must be positive")
    self.programTimescale = programTimescale
    self.selectedSource = selectedSource
  }

  /// Starts a source or establishes a new source-to-Program mapping at a cut.
  /// Existing Program time is deliberately retained.
  public mutating func cut(to sourceID: SourceID) {
    selectedSource = sourceID
    activeClock = nil
    sourceOrigin = nil
    programOrigin = nil
    lastSourceTime = nil
  }

  /// Clears both the selected source and Program timeline.
  public mutating func reset() {
    selectedSource = nil
    lastProgramTime = nil
    lastProgramDuration = nil
    activeClock = nil
    sourceOrigin = nil
    programOrigin = nil
    lastSourceTime = nil
  }

  public mutating func map(_ frame: ProgramSourceFrame<SourceID>)
    -> Result<ProgramMappedFrame<SourceID>, ProgramTimestampMappingError> {
    guard let selectedSource else { return .failure(.noSelectedSource) }
    guard frame.sourceID == selectedSource else { return .failure(.sourceMismatch) }
    guard frame.sourceTime.isValid, frame.sourceTime.isNumeric,
      frame.sourceTime.timescale > 0, frame.sourceTime.value >= 0 else {
      return .failure(.invalidSourceTimestamp)
    }
    guard frame.duration.isValid, frame.duration.isNumeric,
      frame.duration.timescale > 0, frame.duration.epoch == 0,
      frame.duration.value > 0 else {
      return .failure(.invalidSourceDuration)
    }
    guard frame.sourceTime.epoch == 0 else {
      return .failure(.sourceEpochUnsupported(frame.sourceTime.epoch))
    }

    let clock = SourceClock(epoch: frame.sourceTime.epoch, timescale: frame.sourceTime.timescale)
    if let activeClock, activeClock.timescale != clock.timescale {
      return .failure(.sourceTimebaseChanged(expected: activeClock.timescale,
        actual: clock.timescale))
    }
    if let lastSourceTime, CMTimeCompare(frame.sourceTime, lastSourceTime) <= 0 {
      return .failure(.sourceTimestampRegressed)
    }

    if activeClock == nil {
      activeClock = clock
      sourceOrigin = frame.sourceTime
      programOrigin = nextProgramTime()
    }
    guard let sourceOrigin, let programOrigin else {
      return .failure(.programTimestampNotMonotonic)
    }

    let offset = CMTimeConvertScale(CMTimeSubtract(frame.sourceTime, sourceOrigin),
      timescale: programTimescale, method: .roundHalfAwayFromZero)
    let mappedTime = CMTimeAdd(programOrigin, offset)
    let mappedDuration = CMTimeConvertScale(frame.duration, timescale: programTimescale,
      method: .roundHalfAwayFromZero)
    guard mappedTime.isValid, mappedTime.isNumeric, mappedDuration.isValid,
      mappedDuration.isNumeric, mappedDuration.value > 0 else {
      return .failure(.programTimestampNotMonotonic)
    }
    if let lastProgramTime, CMTimeCompare(mappedTime, lastProgramTime) <= 0 {
      return .failure(.programTimestampNotMonotonic)
    }

    lastSourceTime = frame.sourceTime
    lastProgramTime = mappedTime
    lastProgramDuration = mappedDuration
    return .success(ProgramMappedFrame(sourceID: frame.sourceID,
      sourceTime: frame.sourceTime, sourceDuration: frame.duration,
      programTime: mappedTime, programDuration: mappedDuration))
  }

  private func nextProgramTime() -> CMTime {
    guard let lastProgramTime else { return .zero }
    guard let lastProgramDuration else { return lastProgramTime }
    return CMTimeAdd(lastProgramTime, lastProgramDuration)
  }
}

public enum ProgramCutRequestResult<SourceID: Hashable> {
  case queued
  case coalesced(previous: SourceID, replacement: SourceID)
  case ignoredSameSource
  case rejectedMissingSource
}

public enum ProgramFrameSkipReason: Equatable {
  case missingSource
  case nonSelectedSource
  case staleQueuedFrame
  case invalidTimestamp(ProgramTimestampMappingError)
}

public enum ProgramFrameDecision<SourceID: Hashable> {
  case accepted(ProgramMappedFrame<SourceID>)
  case cutApplied(ProgramMappedFrame<SourceID>, flushStaleFrames: Bool)
  case skipped(ProgramFrameSkipReason)
}

/// Decides when a pending cut can land at a valid frame boundary.
///
/// The scheduler has no queue or media ownership. It reports when queued
/// frames must be flushed; the route that owns the queue performs that flush.
public struct ProgramCutScheduler<SourceID: Hashable> {
  public private(set) var selectedSource: SourceID?
  public private(set) var pendingCut: SourceID?
  public private(set) var mapper: ProgramTimestampMapper<SourceID>

  private var availability: [SourceID: Bool] = [:]

  public init(selectedSource: SourceID? = nil, programTimescale: Int32 = 60_000) {
    self.selectedSource = selectedSource
    self.mapper = ProgramTimestampMapper(programTimescale: programTimescale,
      selectedSource: selectedSource)
  }

  public var hasPendingCut: Bool { pendingCut != nil }

  /// Updates source health. An unavailable pending target is discarded before
  /// the next frame so it cannot cause a stale or duplicate cut later.
  public mutating func setSource(_ sourceID: SourceID, available: Bool) {
    availability[sourceID] = available
    if !available, pendingCut == sourceID { pendingCut = nil }
  }

  public func isSourceAvailable(_ sourceID: SourceID) -> Bool {
    availability[sourceID] ?? true
  }

  public mutating func requestCut(to sourceID: SourceID) -> ProgramCutRequestResult<SourceID> {
    guard isSourceAvailable(sourceID) else { return .rejectedMissingSource }
    if sourceID == selectedSource {
      // A rapid A → B → A request resolves to the already selected source;
      // discard the pending B cut instead of emitting a duplicate A cut.
      pendingCut = nil
      return .ignoredSameSource
    }
    if let pendingCut {
      if pendingCut == sourceID { return .ignoredSameSource }
      self.pendingCut = sourceID
      return .coalesced(previous: pendingCut, replacement: sourceID)
    }
    pendingCut = sourceID
    return .queued
  }

  public mutating func ingest(_ frame: ProgramSourceFrame<SourceID>)
    -> ProgramFrameDecision<SourceID> {
    if let pendingCut, !isSourceAvailable(pendingCut) {
      self.pendingCut = nil
    }
    guard isSourceAvailable(frame.sourceID) else { return .skipped(.missingSource) }

    if let pendingCut {
      if frame.sourceID == pendingCut {
        // Trial the new source on a value copy. Invalid target frames are
        // skipped while the old selection and pending cut remain intact.
        var candidateMapper = mapper
        candidateMapper.cut(to: pendingCut)
        switch candidateMapper.map(frame) {
        case let .success(mapped):
          mapper = candidateMapper
          selectedSource = pendingCut
          self.pendingCut = nil
          return .cutApplied(mapped, flushStaleFrames: true)
        case let .failure(error):
          return .skipped(.invalidTimestamp(error))
        }
      }
      if frame.sourceID == selectedSource {
        return .skipped(.staleQueuedFrame)
      }
      return .skipped(.nonSelectedSource)
    }

    guard frame.sourceID == selectedSource else { return .skipped(.nonSelectedSource) }
    switch mapper.map(frame) {
    case let .success(mapped): return .accepted(mapped)
    case let .failure(error): return .skipped(.invalidTimestamp(error))
    }
  }
}

import Foundation

public enum MonitorQualityTier: String, Equatable, Sendable { case nominal, reduced }
public struct MonitorEffectiveQuality: Equatable, Sendable {
  public let tier: MonitorQualityTier
  public let pictureHeightLimit: Int
  public let scopeRefreshHz: Int
  public let scopeSamplingStride: Int
  public init(tier: MonitorQualityTier = .nominal, requestedScopeHz: Int = 15) {
    self.tier = tier
    let requested = [10, 15, 30].contains(requestedScopeHz) ? requestedScopeHz : 15
    pictureHeightLimit = tier == .nominal ? 1080 : 720
    // Twelve requests per second leave cadence headroom above the 10 Hz delivery gate.
    // An explicit user request of 10 Hz remains 10 Hz.
    scopeRefreshHz = tier == .nominal ? requested : min(requested, 12)
    scopeSamplingStride = tier == .nominal ? 2 : 4
  }
  public var label: String { tier == .nominal ? "Requested quality" : "Reduced monitoring quality" }
}

/// Worker-owned metadata policy. Real admission failures supply pressure; cadence skips do not.
/// This changes monitoring quality only; it never changes source focus resolution or GPU leases.
public struct MonitorAdaptivePolicy: Sendable {
  public private(set) var requestedScopeHz: Int
  public private(set) var tier: MonitorQualityTier = .nominal
  private var pressureStart: Double?
  private var lastPressure: Double?
  private var pressureEvents = 0
  private var lastObservation: Double?
  private let pressureWindow: Double
  private let recoveryWindow: Double
  public init(requestedScopeHz: Int = 15, pressureWindow: Double = 1, recoveryWindow: Double = 5) {
    self.requestedScopeHz = [10, 15, 30].contains(requestedScopeHz) ? requestedScopeHz : 15
    self.pressureWindow = pressureWindow.isFinite ? max(1, pressureWindow) : 1
    self.recoveryWindow = recoveryWindow.isFinite ? max(5, recoveryWindow) : 5
  }
  public var quality: MonitorEffectiveQuality {
    MonitorEffectiveQuality(tier: tier, requestedScopeHz: requestedScopeHz)
  }
  public mutating func configure(requestedScopeHz: Int) {
    self.requestedScopeHz = [10, 15, 30].contains(requestedScopeHz) ? requestedScopeHz : 15
  }
  @discardableResult
  public mutating func observe(now: Double, pressured: Bool) -> MonitorEffectiveQuality {
    guard now.isFinite, lastObservation.map({ now >= $0 }) ?? true else { return quality }
    lastObservation = now
    if pressured {
      if lastPressure.map({ now - $0 >= pressureWindow }) ?? true {
        pressureStart = now
        pressureEvents = 0
      }
      lastPressure = now
      pressureEvents = min(3, pressureEvents + 1)
    }
    if tier == .nominal, let start = pressureStart, let last = lastPressure,
      pressureEvents >= 3, now - start >= pressureWindow, now - last < pressureWindow {
      tier = .reduced
    }
    if !pressured, let last = lastPressure, now - last >= recoveryWindow {
      tier = .nominal
      pressureStart = nil
      pressureEvents = 0
      lastPressure = nil
    } else if !pressured, let last = lastPressure, now - last >= pressureWindow {
      pressureStart = nil
      pressureEvents = 0
    }
    return quality
  }
}

public enum MonitorSoftDeadlineStatus: String, Equatable, Sendable {
  case unavailable, withinDeadline, exceeded
}
/// Worker-owned, constant-storage counters. Snapshots may be published at a low UI cadence.
public struct MonitorDiagnosticsAccumulator: Sendable {
  private var value = MonitorDiagnostics()
  private var rateStart: Double?
  private var windowOffers: UInt64 = 0
  private var windowAdmissions: UInt64 = 0
  private var windowPictures: UInt64 = 0
  private var windowScopes: UInt64 = 0
  private var lastPicture: MonitorFrameStamp?
  private var lastScope: MonitorFrameStamp?
  public init() {}
  private func increment(_ count: UInt64) -> UInt64 { count == .max ? count : count + 1 }
  private mutating func start(_ now: Double) { if rateStart == nil, now.isFinite { rateStart = now } }
  public mutating func recordOffer(now: Double) {
    start(now); value.offeredFrames = increment(value.offeredFrames); windowOffers = increment(windowOffers)
  }
  public mutating func recordAdmission(now: Double) {
    start(now); value.admittedFrames = increment(value.admittedFrames); windowAdmissions = increment(windowAdmissions)
  }
  public mutating func recordSkip() { value.skippedFrames = increment(value.skippedFrames) }
  public mutating func recordRejectedResult() { value.rejectedResults = increment(value.rejectedResults) }
  private func isNew(_ stamp: MonitorFrameStamp, after previous: MonitorFrameStamp?) -> Bool {
    guard let previous else { return true }
    if stamp.target != previous.target || stamp.generation != previous.generation { return true }
    return stamp.sequence > previous.sequence
  }
  public mutating func recordPicture(_ stamp: MonitorFrameStamp, now: Double) {
    guard isNew(stamp, after: lastPicture) else { return }
    start(now); lastPicture = stamp; windowPictures = increment(windowPictures)
  }
  public mutating func recordScope(_ stamp: MonitorFrameStamp, now: Double) {
    guard isNew(stamp, after: lastScope) else { return }
    start(now); lastScope = stamp; windowScopes = increment(windowScopes)
  }
  public mutating func snapshot(
    now: Double, budget: MonitorAdmissionSnapshot, quality: MonitorEffectiveQuality,
    requestedScopeHz: Int, requestedPictureHz: Double = 60, staleAfter: Double = 1, softDeadline: Double = 0.25
  ) -> MonitorDiagnostics {
    if let start = rateStart, now.isFinite, now - start >= 1 {
      let elapsed = now - start
      value.offeredFPS = Double(windowOffers) / elapsed
      value.admittedFPS = Double(windowAdmissions) / elapsed
      value.pictureFPS = Double(windowPictures) / elapsed
      value.scopeFPS = Double(windowScopes) / elapsed
      value.analysisFPS = value.admittedFPS
      windowOffers = 0; windowAdmissions = 0; windowPictures = 0; windowScopes = 0
      rateStart = now
    }
    func age(_ stamp: MonitorFrameStamp?) -> Double? {
      guard let stamp, now.isFinite, stamp.hostTime.isFinite else { return nil }
      return max(0, now - stamp.hostTime)
    }
    value.pictureAge = age(lastPicture); value.scopeAge = age(lastScope)
    value.resultAge = value.pictureAge
    value.scopeStale = value.scopeAge.map { $0 > max(0, staleAfter) } ?? true
    value.softDeadlineStatus = value.pictureAge.map { $0 > max(0, softDeadline) ? .exceeded : .withinDeadline } ?? .unavailable
    value.retainedBytes = budget.retainedBytes; value.retiredBytes = budget.retiredBytes
    value.requestedPictureHz = requestedPictureHz.isFinite ? max(0, requestedPictureHz) : 0
    value.requestedScopeHz = requestedScopeHz; value.effectiveQuality = quality
    value.availability = quality.tier == .reduced ? .degraded("Monitoring pressure") : (lastPicture == nil ? .noSignal : .live)
    return value
  }
}

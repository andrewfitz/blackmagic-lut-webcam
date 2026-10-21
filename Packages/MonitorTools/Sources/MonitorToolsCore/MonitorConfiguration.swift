import Foundation

public struct MonitorTargetID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
  public let rawValue: String
  public var id: String { rawValue }
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
/// User-declared transport interpretation; this does not establish camera calibration.
public enum MonitorSourceLogMapping: String, Codable, Sendable, CaseIterable {
  case native10Bit, fullRescaledToLegal10Bit
  public var nativeCodeMapping: NativeLogCodeMapping {
    switch self {
    case .native10Bit: return .native10Bit
    case .fullRescaledToLegal10Bit: return .fullRescaledToLegal10Bit
    }
  }
}
public enum MonitorStage: String, Codable, Sendable, CaseIterable { case source, processedOutput }
public enum MonitorFalseColorMode: String, Codable, Sendable, CaseIterable {
  case off, elZone, sonySLog3, arri
}
public enum MonitorScopeMode: String, Codable, Sendable, CaseIterable {
  case rgbParade, lumaWaveform
}
public enum MonitorZebraMode: String, Codable, Sendable, CaseIterable { case aboveThreshold, band }
public enum MonitorPeakingColor: String, Codable, Sendable, CaseIterable {
  case red, green, blue, yellow, white
}
public struct MonitorGuideSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var thirds = true
  public var centerCross = false
  public var safeArea = false
  public var opacity = 0.65
  public var contrast = 1.0
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case enabled, thirds, centerCross, safeArea, opacity, contrast
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    thirds = try c.decodeIfPresent(Bool.self, forKey: .thirds) ?? thirds
    centerCross = try c.decodeIfPresent(Bool.self, forKey: .centerCross) ?? centerCross
    safeArea = try c.decodeIfPresent(Bool.self, forKey: .safeArea) ?? safeArea
    opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
  }
}
public struct MonitorZebraSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var thresholdIRE = 95.0
  public var widthIRE = 5.0
  public var mode: MonitorZebraMode = .aboveThreshold
  public var opacity = 0.65
  public init() {}
  private enum CodingKeys: String, CodingKey { case enabled, thresholdIRE, widthIRE, mode, opacity }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    thresholdIRE = try c.decodeIfPresent(Double.self, forKey: .thresholdIRE) ?? thresholdIRE
    widthIRE = try c.decodeIfPresent(Double.self, forKey: .widthIRE) ?? widthIRE
    mode = try c.decodeIfPresent(MonitorZebraMode.self, forKey: .mode) ?? mode
    opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
  }
}
public struct MonitorFalseColorSettings: Codable, Equatable, Sendable {
  public var mode: MonitorFalseColorMode = .off
  public var profileID: String?
  public var specificationVersion: String?
  public var exposureIndex = 800
  public var referenceOffsetStops = 0.0
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case mode, profileID, specificationVersion, exposureIndex, referenceOffsetStops
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(MonitorFalseColorMode.self, forKey: .mode) ?? mode
    profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? profileID
    specificationVersion =
      try c.decodeIfPresent(String.self, forKey: .specificationVersion) ?? specificationVersion
    exposureIndex = try c.decodeIfPresent(Int.self, forKey: .exposureIndex) ?? exposureIndex
    referenceOffsetStops =
      try c.decodeIfPresent(Double.self, forKey: .referenceOffsetStops) ?? referenceOffsetStops
  }
}
public struct MonitorFocusSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var color: MonitorPeakingColor = .red
  public var sensitivity = 0.5
  public var noiseRejection = 0.02
  public var opacity = 0.85
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case enabled, color, sensitivity, noiseRejection, opacity
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    color = try c.decodeIfPresent(MonitorPeakingColor.self, forKey: .color) ?? color
    sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? sensitivity
    noiseRejection = try c.decodeIfPresent(Double.self, forKey: .noiseRejection) ?? noiseRejection
    opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
  }
}
public struct MonitorScopeSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var mode: MonitorScopeMode = .rgbParade
  public var gain = 1.0
  public var graticule = true
  public var refreshHz = 15
  public init() {}
  private enum CodingKeys: String, CodingKey { case enabled, mode, gain, graticule, refreshHz }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    mode = try c.decodeIfPresent(MonitorScopeMode.self, forKey: .mode) ?? mode
    gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? gain
    graticule = try c.decodeIfPresent(Bool.self, forKey: .graticule) ?? graticule
    refreshHz = try c.decodeIfPresent(Int.self, forKey: .refreshHz) ?? refreshHz
  }
}
public struct MonitorConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var toolsEnabled = false
  public var guides = MonitorGuideSettings()
  public var zebra = MonitorZebraSettings()
  public var falseColor = MonitorFalseColorSettings()
  public var focus = MonitorFocusSettings()
  public var scopes = MonitorScopeSettings()
  public var pictureStage: MonitorStage = .processedOutput
  public var scopeStage: MonitorStage = .processedOutput
  public var sourceProfileID: String?
  public var sourceCodeRange: MonitorCodeRange?
  public var sourceLogMapping: MonitorSourceLogMapping = .native10Bit
  public init() {}
  public var effectiveZebraEnabled: Bool {
    toolsEnabled && zebra.enabled && falseColor.mode == .off
  }
  public var needsAnalysis: Bool {
    toolsEnabled && (zebra.enabled || falseColor.mode != .off || focus.enabled || scopes.enabled)
  }
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, toolsEnabled, guides, zebra, falseColor, focus, scopes, pictureStage,
      scopeStage, sourceProfileID, sourceCodeRange, sourceLogMapping
  }
  public init(from decoder: Decoder) throws {
    self.init()
    do {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      guard schemaVersion == 1 else {
        self = MonitorConfiguration()
        return
      }
      toolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? false
      guides = try c.decodeIfPresent(MonitorGuideSettings.self, forKey: .guides) ?? guides
      zebra = try c.decodeIfPresent(MonitorZebraSettings.self, forKey: .zebra) ?? zebra
      falseColor =
        try c.decodeIfPresent(MonitorFalseColorSettings.self, forKey: .falseColor) ?? falseColor
      focus = try c.decodeIfPresent(MonitorFocusSettings.self, forKey: .focus) ?? focus
      scopes = try c.decodeIfPresent(MonitorScopeSettings.self, forKey: .scopes) ?? scopes
      pictureStage = try c.decodeIfPresent(MonitorStage.self, forKey: .pictureStage) ?? pictureStage
      scopeStage = try c.decodeIfPresent(MonitorStage.self, forKey: .scopeStage) ?? scopeStage
      sourceProfileID = try c.decodeIfPresent(String.self, forKey: .sourceProfileID)
      sourceCodeRange = try c.decodeIfPresent(MonitorCodeRange.self, forKey: .sourceCodeRange)
      sourceLogMapping =
        try c.decodeIfPresent(MonitorSourceLogMapping.self, forKey: .sourceLogMapping)
        ?? .native10Bit
      self = normalized()
    } catch {
      // A monitor preference must never invalidate the containing feed/camera preferences.
      self = MonitorConfiguration()
    }
  }
  /// Safe immutable snapshot for persistence and shader parameter construction.
  public func normalized() -> MonitorConfiguration {
    guard schemaVersion == 1 else { return MonitorConfiguration() }
    var value = self
    func bounded(_ input: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
      input.isFinite ? min(range.upperBound, max(range.lowerBound, input)) : fallback
    }
    value.guides.opacity = bounded(guides.opacity, 0...1, fallback: 0.65)
    value.guides.contrast = bounded(guides.contrast, 0...1, fallback: 1)
    value.zebra.opacity = bounded(zebra.opacity, 0...1, fallback: 0.65)
    value.zebra.thresholdIRE = bounded(zebra.thresholdIRE, -20...120, fallback: 95)
    value.zebra.widthIRE = bounded(zebra.widthIRE, 0...30, fallback: 5)
    value.focus.sensitivity = bounded(focus.sensitivity, 0...1, fallback: 0.5)
    value.focus.noiseRejection = bounded(focus.noiseRejection, 0...1, fallback: 0.02)
    value.focus.opacity = bounded(focus.opacity, 0...1, fallback: 0.85)
    value.scopes.gain = bounded(scopes.gain, 0.25...4, fallback: 1)
    value.scopes.refreshHz = [10, 15, 30].contains(scopes.refreshHz) ? scopes.refreshHz : 15
    value.falseColor.referenceOffsetStops = bounded(
      falseColor.referenceOffsetStops, -10...10, fallback: 0)
    value.falseColor.exposureIndex = min(12800, max(100, falseColor.exposureIndex))
    if value.falseColor.mode == .arri,
      value.falseColor.profileID == SonyARRIStyleFalseColor.profileID
    {
      value.falseColor.mode = .sonySLog3
      value.falseColor.profileID = SonySLog3FalseColor.profileID
      value.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
    }
    if value.falseColor.mode == .sonySLog3 {
      if !SonySLog3FalseColor.supports(sourceProfileID: sourceProfileID)
        || (value.falseColor.profileID != nil
          && value.falseColor.profileID != SonySLog3FalseColor.profileID)
      {
        value.falseColor.mode = .off
      } else {
        value.falseColor.profileID = SonySLog3FalseColor.profileID
        value.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
      }
    }
    if value.falseColor.mode == .elZone {
      let profile = value.falseColor.profileID
      if !ELZoneProfile.supports(sourceProfileID: sourceProfileID)
        || (profile != nil && profile != ELZoneProfile.profileID
          && profile != ELZonePublicReference.profileID)
      {
        value.falseColor.mode = .off
      } else {
        value.falseColor.profileID = ELZoneProfile.profileID
        value.falseColor.specificationVersion = ELZoneProfile.specificationVersion
      }
    }
    if value.falseColor.mode == .arri, let profile = value.falseColor.profileID {
      if profile == SonyARRIStyleFalseColor.profileID {
        // EI800 belongs to the fixed reference transform, not the source camera.
        if !SonyARRIStyleFalseColor.supports(sourceProfileID: sourceProfileID) {
          value.falseColor.mode = .off
        }
      } else if ARRIFalseColorProfile(rawValue: profile) == nil || sourceProfileID != profile
        || falseColor.exposureIndex != 800
      {
        value.falseColor.mode = .off
      }
    }
    return value
  }
}
public enum MonitorWorkspaceLayout: String, Codable, Sendable, CaseIterable {
  case single, sideBySide, fourUp
  public var tileCount: Int {
    switch self {
    case .single: return 1
    case .sideBySide: return 2
    case .fourUp: return 4
    }
  }
}
public struct MonitorWorkspaceState: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var isConfigured = false
  public var layout: MonitorWorkspaceLayout = .single
  public var tileBindings: [MonitorTargetID?] = [nil, nil, nil, nil]
  public var splitRatio = 0.5
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, isConfigured, layout, tileBindings, splitRatio
  }
  public init(from decoder: Decoder) throws {
    self.init()
    do {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      guard schemaVersion == 1 else {
        self = MonitorWorkspaceState()
        return
      }
      isConfigured = try c.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
      layout = try c.decodeIfPresent(MonitorWorkspaceLayout.self, forKey: .layout) ?? .single
      tileBindings =
        try c.decodeIfPresent([MonitorTargetID?].self, forKey: .tileBindings) ?? tileBindings
      if tileBindings.count < 4 {
        tileBindings += Array(repeating: nil, count: 4 - tileBindings.count)
      }
      splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
      splitRatio = normalizedSplitRatio
    } catch {
      self = MonitorWorkspaceState()
    }
  }

  public var normalizedSplitRatio: Double {
    splitRatio.isFinite ? min(0.8, max(0.2, splitRatio)) : 0.5
  }
}

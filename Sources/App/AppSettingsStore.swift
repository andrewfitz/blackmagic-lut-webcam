import Foundation

/// Stable identity for a configured feed. The raw value is persisted instead of
/// relying on array position, so reordering feeds does not change their
/// identity. `primary` is deterministic for migration from the original
/// single-feed settings format.
struct FeedID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
  typealias RawValue = String

  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }

  init(uuid: UUID) { rawValue = uuid.uuidString.lowercased() }

  init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var id: String { rawValue }

  static let primary = FeedID(rawValue: "00000000-0000-0000-0000-000000000001")
}

enum FeedOutputMode: String, Codable, Equatable, Sendable {
  case separateCameras
  case program
}

enum SwitcherStrategy: String, Codable, Equatable, Sendable {
  case manual
  case fixedInterval
  case dynamicAnalysis
}

struct SwitcherSettings: Codable, Equatable, Sendable {
  var selectedFeedID: FeedID?
  var automatic = false
  var intervalSeconds = 5.0
  var strategy: SwitcherStrategy = .manual

  init(selectedFeedID: FeedID? = nil, automatic: Bool = false,
    intervalSeconds: Double = 5.0, strategy: SwitcherStrategy = .manual) {
    self.selectedFeedID = selectedFeedID
    self.automatic = automatic
    self.intervalSeconds = intervalSeconds
    self.strategy = strategy
  }

  private enum CodingKeys: String, CodingKey {
    case selectedFeedID, automatic, intervalSeconds, strategy
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    selectedFeedID = try values.decodeIfPresent(FeedID.self, forKey: .selectedFeedID)
    automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    intervalSeconds = try values.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 5.0
    strategy = try values.decodeIfPresent(SwitcherStrategy.self, forKey: .strategy) ?? .manual
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  var version = 1
  var selectedDevice = ""
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var gamut = "S-Gamut3.Cine / S-Log3"
  var pipelineEnabled = true
  var previewEnabled = true
  var lutBookmark: Data?
  // Optional on disk to migrate v1 preferences without losing the saved LUT.
  var automaticFeed: Bool?

  var configuration: PipelineConfiguration {
    PipelineConfiguration(applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate)
  }
}

/// Persisted settings for one feed. This is deliberately independent from
/// `AppModel`, which still owns the one-feed runtime path for now.
struct FeedDescriptor: Codable, Equatable, Sendable, Identifiable {
  var version = 1
  var id: FeedID
  var name: String
  var selectedDevice = ""
  var applyLUT = false
  var downscale = true
  var convertTo420 = true
  var reduceFrameRate = false
  var gamut = "S-Gamut3.Cine / S-Log3"
  var pipelineEnabled = true
  var previewEnabled = true
  var lutBookmark: Data?
  var automaticFeed = false
  var enabled = true

  init(id: FeedID = .primary, name: String = "Feed 1", selectedDevice: String = "",
    applyLUT: Bool = false, downscale: Bool = true, convertTo420: Bool = true,
    reduceFrameRate: Bool = false, gamut: String = "S-Gamut3.Cine / S-Log3",
    pipelineEnabled: Bool = true, previewEnabled: Bool = true, lutBookmark: Data? = nil,
    automaticFeed: Bool = false, enabled: Bool = true) {
    self.id = id
    self.name = name
    self.selectedDevice = selectedDevice
    self.applyLUT = applyLUT
    self.downscale = downscale
    self.convertTo420 = convertTo420
    self.reduceFrameRate = reduceFrameRate
    self.gamut = gamut
    self.pipelineEnabled = pipelineEnabled
    self.previewEnabled = previewEnabled
    self.lutBookmark = lutBookmark
    self.automaticFeed = automaticFeed
    self.enabled = enabled
  }

  init(legacy settings: AppSettings, id: FeedID = .primary, name: String = "Feed 1") {
    self.init(id: id, name: name, selectedDevice: settings.selectedDevice,
      applyLUT: settings.applyLUT, downscale: settings.downscale,
      convertTo420: settings.convertTo420, reduceFrameRate: settings.reduceFrameRate,
      gamut: settings.gamut, pipelineEnabled: settings.pipelineEnabled,
      previewEnabled: settings.previewEnabled, lutBookmark: settings.lutBookmark,
      automaticFeed: settings.automaticFeed ?? false)
  }

  var configuration: PipelineConfiguration {
    PipelineConfiguration(applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate)
  }

  var displayName: String {
    get { name }
    set { name = newValue }
  }

  var deviceID: String {
    get { selectedDevice }
    set { selectedDevice = newValue }
  }

  var appSettings: AppSettings {
    AppSettings(selectedDevice: selectedDevice, applyLUT: applyLUT, downscale: downscale,
      convertTo420: convertTo420, reduceFrameRate: reduceFrameRate, gamut: gamut,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled,
      lutBookmark: lutBookmark, automaticFeed: automaticFeed)
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, name, selectedDevice, applyLUT, downscale, convertTo420,
      reduceFrameRate, gamut, pipelineEnabled, previewEnabled, lutBookmark,
      automaticFeed, enabled
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
    id = try values.decodeIfPresent(FeedID.self, forKey: .id) ?? .primary
    name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Feed 1"
    selectedDevice = try values.decodeIfPresent(String.self, forKey: .selectedDevice) ?? ""
    applyLUT = try values.decodeIfPresent(Bool.self, forKey: .applyLUT) ?? false
    downscale = try values.decodeIfPresent(Bool.self, forKey: .downscale) ?? true
    convertTo420 = try values.decodeIfPresent(Bool.self, forKey: .convertTo420) ?? true
    reduceFrameRate = try values.decodeIfPresent(Bool.self, forKey: .reduceFrameRate) ?? false
    gamut = try values.decodeIfPresent(String.self, forKey: .gamut) ?? "S-Gamut3.Cine / S-Log3"
    pipelineEnabled = try values.decodeIfPresent(Bool.self, forKey: .pipelineEnabled) ?? true
    previewEnabled = try values.decodeIfPresent(Bool.self, forKey: .previewEnabled) ?? true
    lutBookmark = try values.decodeIfPresent(Data.self, forKey: .lutBookmark)
    automaticFeed = try values.decodeIfPresent(Bool.self, forKey: .automaticFeed) ?? false
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
  }
}

struct AppSettingsSnapshot: Codable, Equatable, Sendable {
  static let currentVersion = 2

  var version = AppSettingsSnapshot.currentVersion
  var feeds: [FeedDescriptor]
  var selectedFeedID: FeedID
  var outputMode: FeedOutputMode = .separateCameras
  var switcher = SwitcherSettings()
  var virtualCameraRegistryVersion = 1

  init(feeds: [FeedDescriptor] = [FeedDescriptor()], selectedFeedID: FeedID? = nil,
    outputMode: FeedOutputMode = .separateCameras, switcher: SwitcherSettings = SwitcherSettings(),
    virtualCameraRegistryVersion: Int = 1) {
    self.feeds = feeds
    self.selectedFeedID = selectedFeedID ?? feeds.first?.id ?? .primary
    self.outputMode = outputMode
    self.switcher = switcher
    self.virtualCameraRegistryVersion = virtualCameraRegistryVersion
  }

  var selectedFeed: FeedDescriptor? {
    feeds.first(where: { $0.id == selectedFeedID }) ?? feeds.first
  }

  /// Returns a complete, safe snapshot while preserving descriptor ordering.
  /// Invalid IDs or an empty collection indicate corrupt v2 data and are
  /// rejected so the store can fall back to the v1 migration path.
  func validated() -> AppSettingsSnapshot? {
    guard version == Self.currentVersion, !feeds.isEmpty else { return nil }
    var seen = Set<FeedID>()
    for feed in feeds {
      guard feed.version == 1, !feed.id.rawValue.isEmpty, seen.insert(feed.id).inserted else { return nil }
    }
    var result = self
    if !seen.contains(selectedFeedID) { result.selectedFeedID = feeds[0].id }
    if let switcherID = switcher.selectedFeedID, !seen.contains(switcherID) {
      result.switcher.selectedFeedID = result.selectedFeedID
    }
    return result
  }

  private enum CodingKeys: String, CodingKey {
    case version, feeds, selectedFeedID, outputMode, switcher, virtualCameraRegistryVersion
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    feeds = try values.decodeIfPresent([FeedDescriptor].self, forKey: .feeds) ?? []
    selectedFeedID = try values.decodeIfPresent(FeedID.self, forKey: .selectedFeedID)
      ?? feeds.first?.id ?? .primary
    outputMode = try values.decodeIfPresent(FeedOutputMode.self, forKey: .outputMode) ?? .separateCameras
    switcher = try values.decodeIfPresent(SwitcherSettings.self, forKey: .switcher) ?? SwitcherSettings()
    virtualCameraRegistryVersion = try values.decodeIfPresent(Int.self, forKey: .virtualCameraRegistryVersion) ?? 1
  }
}

// Small preferences stay on the main actor. Video state, frame buffers and LUT
// contents are never serialized into defaults.
@MainActor
final class AppSettingsStore {
  static let key = "ultrastudio.settings.v1"
  static let snapshotKey = "ultrastudio.settings.v2"
  static let v2Key = snapshotKey
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func load() -> AppSettings {
    if let snapshot = loadV2() { return snapshot.selectedFeed?.appSettings ?? AppSettings() }
    guard let legacy = loadLegacy() else { return AppSettings() }
    saveSnapshot(AppSettingsSnapshot(feeds: [FeedDescriptor(legacy: legacy)], selectedFeedID: .primary))
    return legacy
  }

  /// Loads the v2 collection and migrates the original one-feed record on the
  /// first read. The v1 value is intentionally retained until a v2 snapshot is
  /// successfully encoded and stored, allowing recovery after a failed write.
  func loadSnapshot() -> AppSettingsSnapshot {
    if let snapshot = loadV2() { return snapshot }
    guard let legacy = loadLegacy() else { return AppSettingsSnapshot() }
    let migrated = AppSettingsSnapshot(feeds: [FeedDescriptor(legacy: legacy)], selectedFeedID: .primary)
    saveSnapshot(migrated)
    return migrated
  }

  func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.key)
  }

  func saveSnapshot(_ snapshot: AppSettingsSnapshot) {
    let snapshot = snapshot.validated() ?? AppSettingsSnapshot()
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: Self.snapshotKey)
  }

  private func loadLegacy() -> AppSettings? {
    guard let data = defaults.data(forKey: Self.key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
      settings.version == 1 else { return nil }
    return settings
  }

  private func loadV2() -> AppSettingsSnapshot? {
    guard let data = defaults.data(forKey: Self.snapshotKey),
      let snapshot = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data) else { return nil }
    return snapshot.validated()
  }
}

struct LoadedLUT: Sendable {
  let cube: CubeLUT
  let bookmark: Data
  let fileName: String
}

// File access and cube parsing run off the main actor. Every security-scope
// lease spans the read only; the GPU receives the parsed immutable cube.
actor LUTFileLoader {
  private let scopedBookmarks: Bool

  init(scopedBookmarks: Bool = true) { self.scopedBookmarks = scopedBookmarks }

  func load(url: URL) throws -> LoadedLUT {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let bookmark = try url.bookmarkData(options: scopedBookmarks
      ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.minimalBookmark],
      includingResourceValuesForKeys: nil, relativeTo: nil)
    return LoadedLUT(cube: try read(url), bookmark: bookmark, fileName: url.lastPathComponent)
  }

  func restore(bookmark: Data) throws -> LoadedLUT {
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark,
      options: scopedBookmarks ? [.withSecurityScope, .withoutUI] : [.withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let cube = try read(url)
    let refreshed = stale ? try url.bookmarkData(options: scopedBookmarks
      ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.minimalBookmark],
      includingResourceValuesForKeys: nil, relativeTo: nil) : bookmark
    return LoadedLUT(cube: cube, bookmark: refreshed, fileName: url.lastPathComponent)
  }

  private func read(_ url: URL) throws -> CubeLUT {
    let limit = 32 * 1024 * 1024
    let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw VideoError.message("Choose a regular .cube file.")
    }
    guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= limit else {
      throw VideoError.message("LUT file exceeds 32 MB.")
    }
    // Bound the actual read as well as the preflight size: a file can grow
    // between stat and read, and an unbounded String initializer allocates it
    // before the parser can enforce its own limit.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var bytes = Data()
    while bytes.count <= limit {
      let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - bytes.count))
      guard let chunk, !chunk.isEmpty else { break }
      bytes.append(chunk)
    }
    guard bytes.count <= limit else { throw VideoError.message("LUT file exceeds 32 MB.") }
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw VideoError.message("LUT file must contain valid UTF-8 text.")
    }
    return try CubeLUT(text: text,
      fallbackTitle: url.deletingPathExtension().lastPathComponent)
  }
}

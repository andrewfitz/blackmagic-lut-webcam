import Foundation

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

// Small preferences stay on the main actor. Video state, frame buffers and LUT
// contents are never serialized into defaults.
@MainActor
final class AppSettingsStore {
  static let key = "ultrastudio.settings.v1"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func load() -> AppSettings {
    guard let data = defaults.data(forKey: Self.key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
      settings.version == 1 else { return AppSettings() }
    return settings
  }

  func save(_ settings: AppSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.key)
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

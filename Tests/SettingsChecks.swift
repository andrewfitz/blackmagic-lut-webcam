import Foundation
import XCTest

@MainActor @objcMembers final class SettingsChecks: XCTestCase {
  func testPreferencesRoundTripWithoutVideoOrRateState() throws {
    let suiteName = "org.ultrastudiolut.tests.settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = AppSettings(selectedDevice: "synthetic-device", applyLUT: true,
      downscale: false, convertTo420: false, reduceFrameRate: true,
      gamut: "S-Gamut3 / S-Log3", pipelineEnabled: false, previewEnabled: false,
      lutBookmark: Data([1, 2, 3]))
    AppSettingsStore(defaults: defaults).save(saved)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).load(), saved)
    let text = String(data: try XCTUnwrap(defaults.data(forKey: AppSettingsStore.key)), encoding: .utf8)!
    XCTAssertFalse(text.contains("inputFast"), "Source rate must be detected each run")
    XCTAssertFalse(text.contains("running"), "Capture must not start automatically")
    XCTAssertFalse(text.contains("rgba"), "LUT payload must not become a preference")
  }

  func testCorruptOrUnsupportedPreferencesUseSafeDefaults() throws {
    let suiteName = "org.ultrastudiolut.tests.settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("invalid JSON".utf8), forKey: AppSettingsStore.key)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).load(), AppSettings())
    var unsupported = AppSettings()
    unsupported.version = 9
    AppSettingsStore(defaults: defaults).save(unsupported)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).load(), AppSettings())
  }

  func testBookmarkRestoreAndMissingFileRecovery() throws {
    let directory = URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-director-work/tmp")
      .appendingPathComponent("settings-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("identity.cube")
    try cubeText().write(to: file, atomically: true, encoding: .utf8)
    let completed = expectation(description: "Bookmark restored off the main actor")
    Task {
      // Tests use ordinary bookmarks because this executable has no sandbox
      // identity. Production always uses the app-scoped, read-only variant.
      let loader = LUTFileLoader(scopedBookmarks: false)
      do {
        let selected = try await loader.load(url: file)
        let restored = try await loader.restore(bookmark: selected.bookmark)
        XCTAssertEqual(restored.cube.dimension, 2)
        XCTAssertEqual(restored.cube.rgba, selected.cube.rgba)
        try FileManager.default.removeItem(at: file)
        do {
          _ = try await loader.restore(bookmark: selected.bookmark)
          XCTFail("A missing LUT must not be reported as loaded")
        } catch { }
        // The saved bookmark remains usable if the file returns.
        try cubeText().write(to: file, atomically: true, encoding: .utf8)
        let recovered = try await loader.restore(bookmark: selected.bookmark)
        XCTAssertEqual(recovered.cube.rgba, selected.cube.rgba)
        do {
          _ = try await loader.restore(bookmark: Data([0, 1, 2]))
          XCTFail("Invalid bookmark must be rejected")
        } catch { }
      } catch { XCTFail(error.localizedDescription) }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
  }

  func testInvalidSelectionDoesNotReplaceSavedBookmark() throws {
    let directory = URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-director-work/tmp")
      .appendingPathComponent("settings-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appendingPathComponent("good.cube")
    let bad = directory.appendingPathComponent("bad.cube")
    try cubeText().write(to: good, atomically: true, encoding: .utf8)
    try "LUT_3D_SIZE 2\n0 0 0".write(to: bad, atomically: true, encoding: .utf8)
    let completed = expectation(description: "Invalid replacement is rejected")
    Task {
      let loader = LUTFileLoader(scopedBookmarks: false)
      do {
        let original = try await loader.load(url: good)
        do {
          _ = try await loader.load(url: bad)
          XCTFail("Invalid cube cannot replace a valid choice")
        } catch { }
        let restored = try await loader.restore(bookmark: original.bookmark)
        XCTAssertEqual(restored.cube.rgba, original.cube.rgba)
      } catch { XCTFail(error.localizedDescription) }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
  }
}

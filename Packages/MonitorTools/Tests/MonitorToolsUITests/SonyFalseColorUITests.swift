import MonitorToolsCore
import SwiftUI
import XCTest

@testable import MonitorToolsUI

final class SonyFalseColorUITests: XCTestCase {
  @MainActor func testELZoneModeSelectionPublishesOneCompleteQualifiedConfiguration() {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.sourceProfileID = source
      selected.falseColor.mode = .sonySLog3
      selected.falseColor.profileID = "sony-slog3-false-color-v1"
      selected.falseColor.specificationVersion = "sony-monitor-control-pattern2-v1"
      selected.falseColor.referenceOffsetStops = 1.25
      selected.falseColor.exposureIndex = 12800
      selected.guides.centerCross = true
      var published: [MonitorConfiguration] = []
      let toolbar = MonitorToolsToolbar(configuration: Binding(
        get: { selected },
        set: {
          published.append($0)
          selected = $0.normalized()
        }))

      XCTAssertTrue(toolbar.isELZoneAvailable)
      XCTAssertFalse(MonitorToolsToolbar(
        configuration: .constant(selected), supportsSourceAnalysis: false).isELZoneAvailable)

      toolbar.falseColorModeSelection.wrappedValue = .elZone

      XCTAssertEqual(published.count, 1, "Normalization must receive the EL profile with its mode")
      XCTAssertEqual(published.first?.falseColor.mode, .elZone)
      XCTAssertEqual(published.first?.falseColor.profileID, "ultracam-elzone-public-chart-v1")
      XCTAssertEqual(
        published.first?.falseColor.specificationVersion, "Ultracam-PanasonicFW9-Midpoints-v1")
      XCTAssertEqual(selected.falseColor.mode, .elZone)
      XCTAssertEqual(selected.falseColor.profileID, "ultracam-elzone-public-chart-v1")
      XCTAssertEqual(selected.falseColor.referenceOffsetStops, 1.25)
      XCTAssertEqual(selected.falseColor.exposureIndex, 12800)
      XCTAssertTrue(selected.guides.centerCross)
    }
  }

  @MainActor func testSonySourceSelectionQualifiesELZoneBeforeCoordinatorNormalization() {
    var selected = MonitorConfiguration()
    selected.falseColor.mode = .elZone
    selected.falseColor.referenceOffsetStops = -0.75
    selected.falseColor.exposureIndex = 3200
    selected.sourceCodeRange = .full
    var published: [MonitorConfiguration] = []
    let toolbar = MonitorToolsToolbar(configuration: Binding(
      get: { selected },
      set: {
        published.append($0)
        selected = $0.normalized()
      }))

    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      toolbar.sourceProfileSelection.wrappedValue = source

      XCTAssertEqual(published.last?.sourceProfileID, source)
      XCTAssertEqual(published.last?.falseColor.mode, .elZone)
      XCTAssertEqual(published.last?.falseColor.profileID, "ultracam-elzone-public-chart-v1")
      XCTAssertEqual(
        published.last?.falseColor.specificationVersion, "Ultracam-PanasonicFW9-Midpoints-v1")
      XCTAssertEqual(selected.falseColor.mode, .elZone)
      XCTAssertEqual(selected.falseColor.referenceOffsetStops, -0.75)
      XCTAssertEqual(selected.falseColor.exposureIndex, 3200)
      XCTAssertEqual(selected.sourceCodeRange, .full)
    }
    XCTAssertEqual(published.count, 2, "Each source switch must publish one complete update")
  }

  @MainActor func testUnknownSavedSourceHasMatchingFallbackWithoutChangingSavedConfiguration() {
    for source in ["unknown-persisted-log", "arri-logc3-ei800", ""] {
      var selected = MonitorConfiguration()
      selected.sourceProfileID = source
      let original = selected
      var writes = 0
      let toolbar = MonitorToolsToolbar(configuration: Binding(
        get: { selected },
        set: {
          writes += 1
          selected = $0.normalized()
        }))

      XCTAssertEqual(toolbar.unsupportedSavedSourceProfileID, source)
      XCTAssertEqual(toolbar.unsupportedSavedSourceProfileID, toolbar.sourceProfileSelection.wrappedValue)
      XCTAssertFalse(toolbar.isSonyFalseColorAvailable)
      XCTAssertFalse(toolbar.isELZoneAvailable)
      XCTAssertEqual(selected, original)
      XCTAssertEqual(writes, 0, "Presenting an unsupported saved input must not replace it")

      toolbar.sourceProfileSelection.wrappedValue = "sony-slog3-sgamut3cine"

      XCTAssertNil(toolbar.unsupportedSavedSourceProfileID)
      XCTAssertTrue(toolbar.isSonyFalseColorAvailable)
      XCTAssertEqual(writes, 1)
    }
    for source in [nil, "sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] as [String?] {
      var configuration = MonitorConfiguration()
      configuration.sourceProfileID = source
      let toolbar = MonitorToolsToolbar(configuration: .constant(configuration))
      XCTAssertNil(toolbar.unsupportedSavedSourceProfileID)
    }
  }

  @MainActor func testSonyModeSelectionPublishesOneCompleteQualifiedConfiguration() throws {
    let sonyMode = try XCTUnwrap(MonitorFalseColorMode(rawValue: "sonySLog3"))
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.sourceProfileID = source
      selected.falseColor.exposureIndex = 12800
      selected.guides.centerCross = true
      let otherFeed = selected
      var published: [MonitorConfiguration] = []
      let toolbar = MonitorToolsToolbar(configuration: Binding(
        get: { selected },
        set: {
          published.append($0)
          selected = $0.normalized()
        }))

      toolbar.falseColorModeSelection.wrappedValue = sonyMode

      XCTAssertEqual(published.count, 1, "Normalization must receive a complete single update")
      XCTAssertEqual(published.first?.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(published.first?.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(
        published.first?.falseColor.specificationVersion, "sony-monitor-control-pattern2-v1")
      XCTAssertEqual(selected.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(selected.falseColor.exposureIndex, 12800)
      XCTAssertTrue(selected.guides.centerCross)
      XCTAssertEqual(otherFeed.falseColor.mode, .off)
      XCTAssertNil(otherFeed.falseColor.profileID)

      toolbar.falseColorModeSelection.wrappedValue = .off

      XCTAssertEqual(published.count, 2)
      XCTAssertEqual(selected.falseColor.mode, .off)
      XCTAssertEqual(selected.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(selected.falseColor.exposureIndex, 12800)
    }
  }

  @MainActor func testSonySourceSelectionQualifiesLegacyModeBeforeCoordinatorNormalization() {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var selected = MonitorConfiguration()
      selected.toolsEnabled = true
      selected.sourceProfileID = "arri-logc3-ei800"
      selected.falseColor.mode = .arri
      selected.falseColor.profileID = "arri-logc3-ei800"
      selected.falseColor.specificationVersion = ARRIFalseColorProfile.specificationVersion
      selected.falseColor.exposureIndex = 1600
      selected.sourceCodeRange = .full
      selected.sourceLogMapping = .fullRescaledToLegal10Bit
      selected.scopes.enabled = true
      var published: [MonitorConfiguration] = []
      let toolbar = MonitorToolsToolbar(configuration: Binding(
        get: { selected },
        set: {
          published.append($0)
          selected = $0.normalized()
        }))

      toolbar.sourceProfileSelection.wrappedValue = source

      XCTAssertEqual(published.count, 1)
      XCTAssertEqual(published.first?.sourceProfileID, source)
      XCTAssertEqual(published.first?.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(published.first?.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(selected.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(selected.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(selected.falseColor.exposureIndex, 1600)
      XCTAssertEqual(selected.sourceCodeRange, .full)
      XCTAssertEqual(selected.sourceLogMapping, .fullRescaledToLegal10Bit)
      XCTAssertTrue(selected.toolsEnabled)
      XCTAssertTrue(selected.scopes.enabled)
    }
  }
}

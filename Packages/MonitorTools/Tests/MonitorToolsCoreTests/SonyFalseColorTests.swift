import Foundation
import XCTest

@testable import MonitorToolsCore

final class SonyFalseColorTests: XCTestCase {
  func testEveryPublishedIREBoundaryUsesHalfOpenIntervals() {
    // Sony Pattern2 values, independently transcribed from the primary help guide.
    let fixtures: [(SonyFalseColorCategory, Double, Double)] = [
      (.red, 93.4, 96.1), (.orange, 87.7, 90.6), (.yellow, 91.3, 93.4),
      (.cyan, 43.8, 46.5), (.pink, 54.3, 58), (.lightPink, 47.8, 50.8),
      (.green, 38.9, 42.2), (.lightBlue, 24.6, 34.4), (.blue, 3.5, 5.6),
      (.purple, -7, 3.5),
    ]
    for (category, lower, upper) in fixtures {
      XCTAssertEqual(SonySLog3FalseColor.category(ire: lower), category)
      XCTAssertEqual(SonySLog3FalseColor.category(ire: upper.nextDown), category)
      XCTAssertNotEqual(SonySLog3FalseColor.category(ire: lower.nextDown), category)
      XCTAssertNotEqual(SonySLog3FalseColor.category(ire: upper), category)
    }
    XCTAssertEqual(SonySLog3FalseColor.category(ire: 93.4), .red)
    XCTAssertEqual(SonySLog3FalseColor.category(ire: 3.5), .blue)
  }

  func testGapsAndHeadroomStayNativeAchromaticGray() throws {
    for ire in [-12.0, 12, 36, 43, 47, 52, 60, 91, 100, 120] {
      XCTAssertNil(SonySLog3FalseColor.category(ire: ire))
      let native = (ire * 8.76 + 64) / 1023
      let color = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: native))
      XCTAssertEqual(color.r, native, accuracy: 1e-12)
      XCTAssertEqual(color.g, native, accuracy: 1e-12)
      XCTAssertEqual(color.b, native, accuracy: 1e-12)
    }
  }

  func testNativeIREAnchorsDoNotUseNormalizedTimes100() throws {
    for (native, expectedIRE) in [
      (0.0, -7.30593607305936), (64.0 / 1023, 0),
      (95.0 / 1023, 3.5388127853881275), (420.0 / 1023, 40.63926940639269),
      (598.0 / 1023, 60.95890410958904), (1, 109.47488584474885),
    ] {
      XCTAssertEqual(
        try XCTUnwrap(SonySLog3FalseColor.ire(nativeNormalized: native)), expectedIRE,
        accuracy: 1e-12)
    }
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: 420.0 / 1023), .green)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: 95.0 / 1023), .blue)
    XCTAssertNil(SonySLog3FalseColor.category(nativeSignalLuma: 1))
  }

  func testTransportMappingIsIndependentFromContainerRange() throws {
    let native = try XCTUnwrap(
      NativeLogCodeMapping.native10Bit.nativeNormalized(transportCode: 554.56))
    let rescaled = try XCTUnwrap(
      NativeLogCodeMapping.fullRescaledToLegal10Bit.nativeNormalized(
        transportCode: 538.8724926686216))
    XCTAssertEqual(native, rescaled, accuracy: 1e-12)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: native), .pink)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: rescaled), .pink)
    // Blindly interpreting the native code as legal normalized signal loses pink.
    let incorrect = try XCTUnwrap(MonitorCodeRange.legal.normalizeLuma(code: 554.56, bitDepth: 10))
    XCTAssertNil(SonySLog3FalseColor.category(nativeSignalLuma: incorrect))
  }

  func testRGBUsesEncodedSignalLumaWithDeclaredTransportMatrix() throws {
    // BT.709 encoded luma=.27054 ->24.2884IRE (gap); BT.2020=.29745 ->27.4301IRE.
    let rgb = MonitorRGB(r: 0.7, g: 0.15, b: 0.2)
    let fallback = try XCTUnwrap(SonySLog3FalseColor.color(rgb: rgb, matrix: .bt709))
    XCTAssertEqual(fallback.r, 0.27054, accuracy: 1e-12)
    XCTAssertEqual(fallback.g, fallback.r)
    XCTAssertEqual(fallback.b, fallback.r)
    XCTAssertEqual(
      SonySLog3FalseColor.color(rgb: rgb, matrix: .bt2020),
      MonitorRGB(r: 0.3, g: 0.65, b: 1))
    XCTAssertEqual(
      SonySLog3FalseColor.color(nativeSignalLuma: 420.0 / 1023), MonitorRGB(r: 0, g: 1, b: 0))
  }

  func testNonfiniteAndOverflowReturnUnavailable() {
    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
      XCTAssertNil(SonySLog3FalseColor.ire(nativeNormalized: value))
      XCTAssertNil(SonySLog3FalseColor.color(nativeSignalLuma: value))
    }
    for value in [Double.nan, .infinity, -.infinity] {
      XCTAssertNil(SonySLog3FalseColor.category(ire: value))
      XCTAssertNil(SonySLog3FalseColor.color(rgb: MonitorRGB(r: value, g: 0, b: 0)))
    }
  }

  func testNewSonyConfigurationDecodesAndRoundTripsAtAnyCameraEI() throws {
    let json = """
      {"toolsEnabled":true,"sourceProfileID":"sony-slog3-sgamut3cine",
       "falseColor":{"mode":"sonySLog3","exposureIndex":12800}}
      """
    let decoded = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.falseColor.mode, .sonySLog3)
    XCTAssertEqual(decoded.falseColor.profileID, "sony-slog3-false-color-v1")
    XCTAssertEqual(decoded.falseColor.specificationVersion, "sony-monitor-control-pattern2-v1")
    XCTAssertEqual(decoded.falseColor.exposureIndex, 12800)
    XCTAssertEqual(
      try JSONDecoder().decode(MonitorConfiguration.self, from: JSONEncoder().encode(decoded)), decoded)
  }

  func testNewSonyModeRejectsUnknownProfileAndSource() {
    for source in [nil, "slog3-sgamut3cine", "arri-logc3-ei800", "unknown"] as [String?] {
      var config = MonitorConfiguration()
      config.falseColor.mode = .sonySLog3
      config.sourceProfileID = source
      XCTAssertFalse(SonySLog3FalseColor.supports(sourceProfileID: source))
      XCTAssertEqual(config.normalized().falseColor.mode, .off)
    }
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var config = MonitorConfiguration()
      config.falseColor.mode = .sonySLog3
      config.sourceProfileID = source
      XCTAssertTrue(SonySLog3FalseColor.supports(sourceProfileID: source))
      XCTAssertEqual(config.normalized().falseColor.mode, .sonySLog3)
      config.falseColor.profileID = "unknown"
      XCTAssertEqual(config.normalized().falseColor.mode, .off)
    }
  }

  func testSavedSonyAdaptationDecodesIntoCurrentPreset() throws {
    let json = """
      {"sourceProfileID":"sony-slog3-sgamut3","falseColor":{"mode":"arri",
       "profileID":"arri-style-slog3-logc3-ei800-v1","specificationVersion":"old","exposureIndex":1600}}
      """
    let config = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(json.utf8))
    XCTAssertEqual(config.falseColor.mode, .sonySLog3)
    XCTAssertEqual(config.falseColor.profileID, "sony-slog3-false-color-v1")
    XCTAssertEqual(config.falseColor.specificationVersion, "sony-monitor-control-pattern2-v1")
    XCTAssertEqual(config.falseColor.exposureIndex, 1600)
    XCTAssertEqual(config.normalized(), config)
  }

  func testLiteralARRIPreferencesStillDecodeWithoutSonyMigration() throws {
    let json = """
      {"sourceProfileID":"arri-logc3-ei800","falseColor":{"mode":"arri",
       "profileID":"arri-logc3-ei800","exposureIndex":800}}
      """
    let config = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(json.utf8))
    XCTAssertEqual(config.falseColor.mode, .arri)
    XCTAssertEqual(config.falseColor.profileID, "arri-logc3-ei800")
  }
}

import CoreMedia
import XCTest

@objcMembers final class SwitcherCoordinatorChecks: XCTestCase {
  private func feed(_ value: String) -> FeedID { FeedID(rawValue: value) }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000)
  }

  private func frame(_ source: FeedID, _ seconds: Double)
    -> ProgramSourceFrame<FeedID> {
    ProgramSourceFrame(sourceID: source, sourceTime: time(seconds),
      duration: time(1.0 / 30.0))
  }

  func testManualCutAppliesAtTargetFrameAndAcknowledgesSelection() {
    let a = feed("A")
    let b = feed("B")
    var coordinator = SwitcherCoordinator(feedIDs: [a, b])
    XCTAssertEqual(coordinator.selectedFeedID, a)
    guard case .queued = coordinator.requestManualCut(to: b) else {
      return XCTFail("manual cut should queue")
    }
    XCTAssertEqual(coordinator.selectedFeedID, a)
    if case let .cutApplied(mapped, flush) = coordinator.ingest(frame(b, 0)) {
      XCTAssertEqual(mapped.sourceID, b)
      XCTAssertTrue(flush)
    } else {
      XCTFail("target frame should apply the queued cut")
    }
    XCTAssertEqual(coordinator.selectedFeedID, b)
    XCTAssertTrue(coordinator.acknowledgeCut(to: b))
    XCTAssertFalse(coordinator.hasPendingCut)
  }

  func testFixedIntervalAdvancesInStableOrderAndSkipsUnhealthyFeed() {
    let a = feed("A")
    let b = feed("B")
    let c = feed("C")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 2, strategy: .fixedInterval)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b, c])
    coordinator.setFeedHealth(b, healthy: false)
    XCTAssertEqual(coordinator.evaluate(at: time(0)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(1.9)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(2)), .cutQueued(c))
    XCTAssertEqual(coordinator.pendingCut, c)
    _ = coordinator.ingest(frame(c, 0))
    XCTAssertEqual(coordinator.selectedFeedID, c)
  }

  func testDynamicAnalysisIsAnExplicitDisabledStub() {
    let a = feed("A")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 1, strategy: .dynamicAnalysis)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, feed("B")])
    XCTAssertEqual(coordinator.statusMessage, "Coming later")
    XCTAssertEqual(coordinator.evaluate(at: time(10)), .dynamicAnalysisUnavailable)
    XCTAssertNil(coordinator.pendingCut)
  }

  func testNaturalDirectorDecisionRequiresExactAcknowledgement() {
    let a = feed("A")
    let b = feed("B")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 5, strategy: .manual)
    var directorSettings = NaturalTalkingHeadDirectorSettings()
    directorSettings.minimumShotDuration = 0
    directorSettings.candidateDwell = 0
    directorSettings.boundaryWindow = 0.3
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b],
      directorSettings: directorSettings)
    let cue = TranscriptCue(timeRange: CMTimeRange(start: time(0.8), end: time(1)),
      kind: .sentenceEnd, confidence: 1, isFinal: true)
    let input = NaturalTalkingHeadDirectorInput(mediaTime: time(1),
      currentCameraID: a.rawValue, anchorCameraID: a.rawValue,
      emphasisCameraID: b.rawValue, cameraHealth: [a.rawValue: true, b.rawValue: true],
      audioCues: [AudioCue(time: time(1), speechEnergy: 1, pauseDuration: 0,
        emphasis: 1, laughter: 0)], transcriptCues: [cue])
    guard let decision = coordinator.evaluateDirector(input) else {
      return XCTFail("director should emit a deterministic decision")
    }
    XCTAssertFalse(coordinator.acknowledgeCut(CutDecision(targetCameraID: b.rawValue,
      cutTime: time(1), confidence: decision.confidence, reason: "wrong")))
    XCTAssertTrue(coordinator.acknowledgeCut(decision))
    XCTAssertFalse(coordinator.acknowledgeCut(decision))
  }

  static let allTests = [
    ("manual cut boundary and acknowledgement", testManualCutAppliesAtTargetFrameAndAcknowledgesSelection),
    ("fixed interval health", testFixedIntervalAdvancesInStableOrderAndSkipsUnhealthyFeed),
    ("dynamic analysis stub", testDynamicAnalysisIsAnExplicitDisabledStub),
    ("natural director acknowledgement", testNaturalDirectorDecisionRequiresExactAcknowledgement),
  ]
}

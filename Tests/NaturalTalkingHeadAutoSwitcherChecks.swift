import CoreMedia
import XCTest

@objcMembers final class NaturalTalkingHeadAutoSwitcherChecks: XCTestCase {
  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000)
  }

  private func input(at seconds: Double, current: String = "A", health: [CameraID: Bool] = ["A": true, "B": true],
    emphasis: Float = 0, pause: TimeInterval = 0, transcript: [TranscriptCue] = []) -> NaturalTalkingHeadDirectorInput {
    NaturalTalkingHeadDirectorInput(mediaTime: time(seconds), currentCameraID: current,
      anchorCameraID: "A", emphasisCameraID: "B", cameraHealth: health,
      audioCues: [AudioCue(time: time(seconds), speechEnergy: emphasis, pauseDuration: pause,
        emphasis: emphasis, laughter: 0)], transcriptCues: transcript)
  }

  func testCutsOnlyAfterDwellAtFinalSentenceBoundaryAndAcknowledgesOnce() {
    var settings = NaturalTalkingHeadDirectorSettings()
    settings.minimumShotDuration = 1
    settings.candidateDwell = 0.25
    settings.boundaryWindow = 0.3
    var director = NaturalTalkingHeadDirector(settings: settings)
    _ = director.evaluate(input(at: 0))
    let cue = TranscriptCue(timeRange: CMTimeRange(start: time(4.8), end: time(5)),
      kind: .sentenceEnd, confidence: 0.95, isFinal: true)
    XCTAssertNil(director.evaluate(input(at: 5, emphasis: 0.95, transcript: [cue])))
    XCTAssertEqual(director.state, .candidateCut)
    let decision = director.evaluate(input(at: 5.3, emphasis: 0.95, transcript: [cue]))
    XCTAssertEqual(decision?.targetCameraID, "B")
    XCTAssertEqual(decision?.cutTime, time(5))
    XCTAssertTrue(decision?.reason.contains("sentence boundary") == true)
    XCTAssertNil(director.evaluate(input(at: 5.4, emphasis: 0.95, transcript: [cue])))
    XCTAssertTrue(director.acknowledgeOutput(decision!))
    XCTAssertFalse(director.acknowledgeOutput(decision!))
  }

  func testMinimumHoldCooldownAndVolatileTranscriptDoNotDuplicate() {
    var settings = NaturalTalkingHeadDirectorSettings()
    settings.minimumShotDuration = 4
    settings.cooldown = 2
    settings.candidateDwell = 0
    settings.boundaryWindow = 0.3
    var director = NaturalTalkingHeadDirector(settings: settings)
    _ = director.evaluate(input(at: 0))
    let first = TranscriptCue(timeRange: CMTimeRange(start: time(4.8), end: time(5)),
      kind: .sentenceEnd, confidence: 0.9, isFinal: false)
    XCTAssertNil(director.evaluate(input(at: 3.9, emphasis: 1, transcript: [first])))
    let revised = TranscriptCue(timeRange: CMTimeRange(start: time(4.8), end: time(5)),
      kind: .sentenceEnd, confidence: 0.96, isFinal: true)
    let decision = director.evaluate(input(at: 5, emphasis: 1, transcript: [revised]))
    XCTAssertNotNil(decision)
    XCTAssertTrue(director.acknowledgeOutput(decision!))

    // The same volatile range remains committed and cooldown suppresses a
    // second decision even while audio is still emphatic.
    XCTAssertNil(director.evaluate(input(at: 5.5, current: "B", emphasis: 1, transcript: [revised])))
  }

  func testReturnsToAnchorAfterEmphasisResolvesAndSkipsUnhealthyTarget() {
    var settings = NaturalTalkingHeadDirectorSettings()
    settings.minimumShotDuration = 0
    settings.emphasisHold = 1
    settings.candidateDwell = 0
    settings.boundaryWindow = 0.3
    var director = NaturalTalkingHeadDirector(settings: settings)
    _ = director.evaluate(input(at: 0))
    let emphasisCue = TranscriptCue(timeRange: CMTimeRange(start: time(1.8), end: time(2)),
      kind: .sentenceEnd, confidence: 0.95, isFinal: true)
    XCTAssertNotNil(director.evaluate(input(at: 2, emphasis: 1, transcript: [emphasisCue])))

    let unhealthy = input(at: 2.1, health: ["A": true, "B": false], emphasis: 1, transcript: [emphasisCue])
    XCTAssertNil(director.evaluate(unhealthy))
    XCTAssertTrue(director.acknowledgeOutput(director.lastDecision!))

    let resolved = TranscriptCue(timeRange: CMTimeRange(start: time(3.8), end: time(4)),
      kind: .sentenceEnd, confidence: 0.95, isFinal: true)
    let returnDecision = director.evaluate(input(at: 4, current: "B", emphasis: 0.05,
      transcript: [resolved]))
    XCTAssertEqual(returnDecision?.targetCameraID, "A")
    XCTAssertTrue(returnDecision?.reason.contains("emphasis resolved") == true)
  }

  func testInvalidAndBackwardsClockTimesClearCandidatesWithoutUnsafeCuts() throws {
    var settings = NaturalTalkingHeadDirectorSettings()
    settings.minimumShotDuration = 0
    settings.candidateDwell = 0
    var director = NaturalTalkingHeadDirector(settings: settings)
    _ = director.evaluate(input(at: 0))
    let cue = TranscriptCue(timeRange: CMTimeRange(start: time(0.8), end: time(1)),
      kind: .sentenceEnd, confidence: 1, isFinal: true)
    let firstDecision = try XCTUnwrap(director.evaluate(input(at: 1, emphasis: 1, transcript: [cue])))
    XCTAssertTrue(director.acknowledgeOutput(firstDecision))
    let backwards = NaturalTalkingHeadDirectorInput(mediaTime: time(0.5), currentCameraID: "A",
      anchorCameraID: "A", emphasisCameraID: "B", audioCues: [], transcriptCues: [])
    XCTAssertNil(director.evaluate(backwards))
    XCTAssertEqual(director.state, .holdAnchor)
    let restartedCue = TranscriptCue(timeRange: CMTimeRange(start: time(0.8), end: time(1)),
      kind: .sentenceEnd, confidence: 1, isFinal: true)
    XCTAssertNotNil(director.evaluate(input(at: 1, emphasis: 1, transcript: [restartedCue])),
      "A restarted timeline must be able to reuse a previously committed boundary timestamp")
    let invalid = NaturalTalkingHeadDirectorInput(mediaTime: .invalid, currentCameraID: "A",
      anchorCameraID: "A", emphasisCameraID: "B")
    XCTAssertNil(director.evaluate(invalid))
  }
}

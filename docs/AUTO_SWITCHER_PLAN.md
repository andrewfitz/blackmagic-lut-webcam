# Natural talking-head auto-switcher plan

## Scope

This plan covers only the automatic director that chooses when to cut between two existing processed camera angles of one seated talking-head subject. Capture, LUT/effects processing, preview rendering, virtual-camera output, and media telemetry already exist elsewhere in the application.

The director consumes timestamped audio and transcript cues and emits timestamped camera-cut decisions. It does not own media buffers or render video.

## Director contract

```swift
struct AudioCue {
    let time: CMTime
    let speechEnergy: Float
    let pauseDuration: TimeInterval
    let emphasis: Float
    let laughter: Float
}

struct TranscriptCue {
    let timeRange: CMTimeRange
    let kind: CueKind       // phraseEnd, sentenceEnd, question, transition
    let confidence: Float
    let isFinal: Bool
}

struct CutDecision {
    let targetCameraID: CameraID
    let cutTime: CMTime
    let confidence: Float
    let reason: String
}
```

The director also receives the current camera, camera roles, camera health, and the last-cut timestamp. It returns either no decision or one `CutDecision` for a given media-clock position.

## Camera roles

The first profile assigns stable editorial roles rather than choosing angles randomly:

```text
Anchor:
  default angle, pauses, uncertain cues, and long explanations

Emphasis:
  tighter or more expressive angle used for important delivery
```

The anchor is the safe fallback. The emphasis angle is selected when the delivery creates a strong editorial beat and the cut can land cleanly.

## Cue processing

The cue detector converts the existing audio and transcript streams into stable events.

Audio cues include:

- speech start and stop
- short pauses and breaths
- sustained energy changes
- emphasis or prosody changes
- laughter or other vocal reactions

Transcript cues include:

- phrase endings
- sentence endings
- questions
- transition words
- audio time ranges
- confidence and finalization state

Transcript text is used primarily for timing in v1. The director does not attempt broad semantic interpretation of every sentence.

Volatile transcript updates must be replaceable. A revised transcript cannot produce duplicate cuts or undo a decision that has already been committed.

## State machine

```text
HOLD_CURRENT
  -> CANDIDATE_CUT
  -> WAIT_FOR_SAFE_BOUNDARY
  -> CUT
  -> HOLD_NEW_SHOT
  -> CANDIDATE_RETURN
  -> HOLD_ANCHOR
```

`HOLD_CURRENT` is the default state. `CANDIDATE_CUT` accumulates evidence without changing output. `WAIT_FOR_SAFE_BOUNDARY` waits for a phrase boundary, sentence boundary, breath, or short pause. `CUT` emits one decision and starts the cooldown. `HOLD_NEW_SHOT` prevents an immediate reversal. `CANDIDATE_RETURN` waits for the emphasis beat to resolve before returning to the anchor.

## Decision rules

A cut to the emphasis angle requires:

```text
strong enough audio emphasis
+ a phrase or sentence boundary nearby
+ minimum shot duration satisfied
+ cooldown expired
+ target camera healthy
+ target has not just been shown
```

A return to the anchor requires:

```text
the thought has resolved
+ delivery energy has settled
+ emphasis shot has served its minimum hold
```

Audio level alone never triggers a cut. It raises or lowers confidence; a boundary or pause supplies the edit window.

The director rejects cues that would create nervous edits, including immediate A → B → A reversals, cuts before the minimum hold, low-confidence transcript boundaries, and repeated volatile results for the same audio time range.

## Scoring model

The initial score is configurable and should be tuned with replay fixtures:

```text
cutScore =
    boundaryConfidence
  + emphasisScore
  + pauseScore
  + pacingNeed
  + targetFreshness
  - rapidRecutPenalty
  - lowConfidencePenalty
  - insufficientHoldPenalty
```

The score must exceed a cut threshold and beat the current-shot score by a hysteresis margin for the candidate dwell period. A decision is emitted at most once for each media-clock interval.

## Timing defaults

Expose these as profile settings, with the following starting defaults:

```text
minimumShotDuration: 4–6 seconds
cooldown: 1–2 seconds
emphasisHold: 4–8 seconds
softMaximumShotDuration: 15–25 seconds
boundaryWindow: 120–300 ms
candidateDwell: 250–400 ms
```

The soft maximum prevents an indefinitely static result but never forces a cut when there is no safe editorial cue.

Transcript-assisted mode may use a synchronized 250–600 ms output delay to wait for cleaner boundaries. Low-latency mode makes decisions from audio and already-arrived transcript information without adding a deliberate delay.

## Output behavior

The director emits an explainable reason with every cut:

```text
Camera B · sentence boundary + strong emphasis
Camera A · emphasis resolved
Held current · no safe edit point
Held current · minimum shot duration not met
```

The existing output coordinator applies the decision at the first valid video-frame boundary at or after `cutTime`. The auto-switcher never manipulates frame ownership, pixel buffers, LUTs, or output routes.

## Settings and UI

Expose the following controls for the Natural Talking Head profile:

- auto-switch enabled
- anchor camera
- emphasis camera
- Low Latency / Transcript Assisted mode
- minimum shot duration
- cooldown
- emphasis hold
- soft maximum shot duration
- calm ↔ active pacing bias
- transcript confidence threshold
- manual hold and immediate camera override

Show the current camera, confidence, pending candidate, and last decision reason. A manual override clears the pending candidate and starts a fresh cooldown.

## Fallbacks

```text
Transcript unavailable → audio-only cue mode
Audio unavailable → hold anchor
Camera unhealthy → remove it from candidates
Clock discontinuity → clear candidates and return to anchor
No safe cue before soft maximum → continue holding
```

The fallback must be visible in diagnostics and must not silently switch to fixed-interval behavior.

## Verification

Build deterministic replay tests from timestamped audio/transcript fixtures. Verify that the director:

- does not cut mid-word when a safe boundary is available
- respects minimum shot duration and cooldown
- does not duplicate cuts from volatile transcript updates
- returns to the anchor after an emphasis beat resolves
- holds during uncertain or conflicting cues
- skips an unhealthy target camera
- preserves monotonic cut timestamps
- produces a reason and confidence for every emitted decision
- behaves consistently in low-latency and transcript-assisted modes

Use recorded session traces only as local test fixtures; do not commit footage or private audio.

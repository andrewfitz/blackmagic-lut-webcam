import CoreMedia

struct FrameRateGate {
  private var last: CMTime = .invalid
  private var lastDuration: CMTime = .invalid

  mutating func reset() {
    last = .invalid
    lastDuration = .invalid
  }

  mutating func shouldDeliver(_ pts: CMTime, duration: CMTime) -> Bool {
    // A gate is a timing boundary, so reject clocks it cannot compare. In
    // particular, an indefinite duration previously made the threshold NaN
    // and allowed every frame through while an epoch-bearing PTS could poison
    // the next source generation.
    guard pts.isValid, pts.isNumeric, pts.epoch == 0,
      duration.isValid, duration.isNumeric, duration.epoch == 0, duration.seconds > 0 else { return false }
    if last.isValid, lastDuration.isValid, CMTimeCompare(lastDuration, duration) != 0 {
      // Callers normally reset on a source-rate change. Keeping this local
      // makes the gate safe for direct users and prevents one old-rate frame
      // from suppressing the first frame of a new cadence.
      last = .invalid
    }
    if last.isValid {
      let ordering = CMTimeCompare(pts, last)
      if ordering == 0 {
        // A duplicate timestamp is never a new video frame.
        return false
      }
      if ordering > 0 {
        let delta = CMTimeSubtract(pts, last)
        // A valid CMTime subtraction can still overflow for extreme values.
        // Refuse to publish when the cadence cannot be represented reliably.
        guard delta.isValid, delta.isNumeric, delta.epoch == 0 else { return false }
        // Allow source-clock jitter while selecting every second 59.94 frame.
        if delta.seconds < duration.seconds * 0.9 { return false }
      }
      // A backwards source clock re-anchors the gate at the new generation.
    }
    last = pts
    lastDuration = duration
    return true
  }
}

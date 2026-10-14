import CoreMedia

struct FrameRateGate {
  private var last: CMTime = .invalid

  mutating func shouldDeliver(_ pts: CMTime, duration: CMTime) -> Bool {
    guard pts.isValid, pts.isNumeric else { return false }
    if last.isValid {
      let delta = CMTimeSubtract(pts, last)
      // Allow source-clock jitter while selecting every second 59.94 frame.
      if delta.seconds >= 0 && delta.seconds < duration.seconds * 0.9 { return false }
    }
    last = pts
    return true
  }
}

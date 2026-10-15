// A failed start is attempted once per camera-use session. Repeated property
// notifications or status updates must never create an automatic retry loop.
struct AutomaticFeedPolicy {
  enum Action: Equatable { case start, stop }
  private(set) var requested = false
  private var attempted = false

  mutating func demand(_ requested: Bool) {
    if self.requested != requested { attempted = false }
    self.requested = requested
  }

  mutating func retry() { attempted = false }

  mutating func action(ready: Bool, running: Bool) -> Action? {
    if !requested { return running ? .stop : nil }
    guard ready, !running, !attempted else { return nil }
    attempted = true
    return .start
  }
}

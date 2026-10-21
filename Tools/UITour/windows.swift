import CoreGraphics

// Prints "id<TAB>layer<TAB>title" for each on-screen window of one process (by
// PID), so the tour captures that app's windows and menus and nothing else, even
// while another copy of Ultracam is running.
guard let pid = CommandLine.arguments.dropFirst().first.flatMap(Int.init) else { fatalError("Usage: windows <pid>") }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerPID as String] as? Int == pid {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  // Skip the status item and other slivers; keep windows and open menus.
  guard (bounds["Width"] as? Double ?? 0) > 40, (bounds["Height"] as? Double ?? 0) > 40 else { continue }
  let id = window[kCGWindowNumber as String] as? Int ?? 0
  let layer = window[kCGWindowLayer as String] as? Int ?? 0
  print("\(id)\t\(layer)\t\(window[kCGWindowName as String] as? String ?? "")")
}

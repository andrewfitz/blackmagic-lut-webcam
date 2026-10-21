import CoreGraphics
import Foundation

// Scrolls by LINES at screen point x y (top-left origin), like a mouse wheel; negative scrolls down.
let values = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard values.count == 3 else { fatalError("Usage: scroll x y lines") }
let point = CGPoint(x: values[0], y: values[1])
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
let lines = Int32(values[2])
for _ in 0..<abs(lines) {
  CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines < 0 ? -1 : 1, wheel2: 0, wheel3: 0)?
    .post(tap: .cghidEventTap)
  usleep(30_000)
}

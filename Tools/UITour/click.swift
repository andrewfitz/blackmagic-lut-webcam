import CoreGraphics
import Foundation

// Clicks the left mouse button at screen point x y (top-left origin), like a person would.
let values = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard values.count == 2 else { fatalError("Usage: click x y") }
let point = CGPoint(x: values[0], y: values[1])
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(type == .mouseMoved ? 120_000 : 60_000)
}

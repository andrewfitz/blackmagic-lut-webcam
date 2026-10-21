import SwiftUI

public struct MonitorScopeGraticule: View {
  public var showGrid: Bool
  public init(showGrid: Bool = true) { self.showGrid = showGrid }
  public var body: some View {
    GeometryReader { proxy in
      ForEach([-10, 0, 50, 100, 110], id: \.self) { level in
        let y = proxy.size.height * (110 - Double(level)) / 120
        if showGrid {
          Path { path in
            path.move(to: CGPoint(x: 25, y: y))
            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
          }
          .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        Text("\(level)").font(.system(size: 8, design: .monospaced)).foregroundStyle(
          .white.opacity(0.8)
        )
        .position(x: 12, y: min(proxy.size.height - 5, max(5, y)))
      }
    }.allowsHitTesting(false).accessibilityLabel("Scope scale minus 10 to 110 IRE")
  }
}

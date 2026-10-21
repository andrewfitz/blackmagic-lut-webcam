import SwiftUI

/// Surface-local center crop applied once to the picture and every picture-space overlay.
public struct MonitorPictureZoom: ViewModifier {
  public let scale: Double
  public init(_ requestedScale: Double) {
    scale = requestedScale.isFinite ? min(4, max(1, requestedScale)) : 1
  }
  public func body(content: Content) -> some View { content.scaleEffect(scale).clipped() }
}

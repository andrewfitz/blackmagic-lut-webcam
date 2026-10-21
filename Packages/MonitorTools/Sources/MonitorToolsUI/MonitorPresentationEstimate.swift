import Foundation

/// Estimated OS compositor storage; exact owned CVPixelBuffer/Metal texture storage is charged separately.
public enum MonitorPresentationEstimate {
  public static let scopeDrawableCount = 2
  public static let scopeBytes = 768 * 256 * 4 * scopeDrawableCount
  public static func pictureBytes(backingWidth: Int, backingHeight: Int) -> Int {
    let width = min(32768, max(1, backingWidth))
    let height = min(32768, max(1, backingHeight))
    return width * height * 4 * 2
  }
  public static func bytes(backingWidth: Int, backingHeight: Int, scopes: Bool) -> Int {
    pictureBytes(backingWidth: backingWidth, backingHeight: backingHeight)
      + (scopes ? scopeBytes : 0)
  }
}

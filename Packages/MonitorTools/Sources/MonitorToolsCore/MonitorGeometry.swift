import Foundation

public struct MonitorPoint: Equatable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}
public struct MonitorRect: Equatable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
  }
}
public enum MonitorOrientation: Int, Codable, Sendable {
  case upright = 0
  case right = 90
  case upsideDown = 180
  case left = 270
}
public struct MonitorGeometry: Equatable, Codable, Sendable {
  public var width: Int
  public var height: Int
  public var cleanAperture: MonitorRect
  public var pixelAspectRatio: Double
  public var orientation: MonitorOrientation
  public init(
    width: Int, height: Int, cleanAperture: MonitorRect? = nil, pixelAspectRatio: Double = 1,
    orientation: MonitorOrientation = .upright
  ) {
    self.width = width
    self.height = height
    self.cleanAperture = cleanAperture ?? MonitorRect(width: Double(width), height: Double(height))
    self.pixelAspectRatio = pixelAspectRatio
    self.orientation = orientation
  }
  public var isValid: Bool {
    width > 0 && height > 0 && cleanAperture.isValid && pixelAspectRatio.isFinite
      && pixelAspectRatio > 0 && cleanAperture.x >= 0 && cleanAperture.y >= 0
      && cleanAperture.x + cleanAperture.width <= Double(width)
      && cleanAperture.y + cleanAperture.height <= Double(height)
  }
  public func aspectFit(in viewport: MonitorRect) -> MonitorRect? {
    guard isValid, viewport.isValid else { return nil }
    let rotated = orientation == .right || orientation == .left
    let w = rotated ? cleanAperture.height : cleanAperture.width * pixelAspectRatio
    let h = rotated ? cleanAperture.width * pixelAspectRatio : cleanAperture.height
    let scale = min(viewport.width / w, viewport.height / h)
    return MonitorRect(
      x: viewport.x + (viewport.width - w * scale) / 2,
      y: viewport.y + (viewport.height - h * scale) / 2, width: w * scale, height: h * scale)
  }
  /// Maps stored pixel centers into the aspect-fit view, including clean aperture and rotation.
  public func mapToView(_ point: MonitorPoint, viewport: MonitorRect) -> MonitorPoint? {
    guard let fit = aspectFit(in: viewport) else { return nil }
    let u = (point.x - cleanAperture.x) / cleanAperture.width
    let v = (point.y - cleanAperture.y) / cleanAperture.height
    let mapped: MonitorPoint
    switch orientation {
    case .upright: mapped = MonitorPoint(x: u, y: v)
    case .right: mapped = MonitorPoint(x: 1 - v, y: u)
    case .upsideDown: mapped = MonitorPoint(x: 1 - u, y: 1 - v)
    case .left: mapped = MonitorPoint(x: v, y: 1 - u)
    }
    return MonitorPoint(x: fit.x + mapped.x * fit.width, y: fit.y + mapped.y * fit.height)
  }
}
/// Producer-declared affine pixel-center mapping. Never inferred from dimensions alone.
public struct MonitorCorrespondence: Equatable, Codable, Sendable {
  public var scaleX: Double
  public var scaleY: Double
  public var offsetX: Double
  public var offsetY: Double
  public init(scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double) {
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.offsetX = offsetX
    self.offsetY = offsetY
  }
  public static let identity = MonitorCorrespondence(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
  public func map(_ point: MonitorPoint) -> MonitorPoint? {
    guard scaleX.isFinite, scaleY.isFinite, scaleX != 0, scaleY != 0, offsetX.isFinite,
      offsetY.isFinite, point.x.isFinite, point.y.isFinite
    else { return nil }
    return MonitorPoint(x: point.x * scaleX + offsetX, y: point.y * scaleY + offsetY)
  }
}

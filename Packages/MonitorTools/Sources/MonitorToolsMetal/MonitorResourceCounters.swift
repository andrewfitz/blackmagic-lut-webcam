import Foundation
import CoreVideo

/// Cumulative runtime image payload copied or bound, excluding row padding/zero-fill.
/// Bound bytes describe an avoided payload upload, not additional memory or GPU utilization.
/// Pool capacity is a conservative reservation bound, rather than physical allocated bytes.
public struct MonitorResourceStatistics: Equatable, Sendable {
  public var cleanCopiedBytes: Int64 = 0
  public var stagingCopiedBytes: Int64 = 0
  public var ownedInputBoundBytes: Int64 = 0
  public var compositeAllocations: Int = 0
  public var compositeReuses: Int = 0
  public var compositePoolFailures: Int = 0
  public var compositePoolCapacityBytes: Int = 0
}

final class MonitorResourceCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var value = MonitorResourceStatistics()

  /// Active image bytes copied; excludes allocator padding and padding zero-fill.
  static func imageBytes(_ buffer: CVPixelBuffer) -> Int {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    if CVPixelBufferGetPlaneCount(buffer) == 0 {
      return (format == kCVPixelFormatType_32BGRA ? width * 4 : ((width + 5) / 6) * 16) * height
    }
    let ten = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange].contains(format)
    return (0..<CVPixelBufferGetPlaneCount(buffer)).reduce(0) {
      $0 + CVPixelBufferGetWidthOfPlane(buffer, $1) * CVPixelBufferGetHeightOfPlane(buffer, $1)
        * (ten ? 2 : 1) * ($1 == 0 ? 1 : 2)
    }
  }

  func record(cleanCopiedBytes: Int = 0, stagingCopiedBytes: Int = 0, ownedInputBoundBytes: Int = 0) {
    lock.lock()
    defer { lock.unlock() }
    value.cleanCopiedBytes += Int64(cleanCopiedBytes)
    value.stagingCopiedBytes += Int64(stagingCopiedBytes)
    value.ownedInputBoundBytes += Int64(ownedInputBoundBytes)
  }

  func snapshot(pool: MonitorCompositePool.Stats) -> MonitorResourceStatistics {
    lock.lock()
    var result = value
    lock.unlock()
    result.compositeAllocations = pool.allocations
    result.compositeReuses = pool.reuses
    result.compositePoolFailures = pool.poolFailures
    result.compositePoolCapacityBytes = pool.poolCapacityBytes
    return result
  }
}

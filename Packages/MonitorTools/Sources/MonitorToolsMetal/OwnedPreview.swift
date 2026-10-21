@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Metal
import MonitorToolsCore

public struct MonitorFrameSignal: Sendable {
  public let range: MonitorCodeRange
  public let matrix: MonitorYCbCrMatrix
  public let transfer: String
  public let profileID: String?
  public init(
    range: MonitorCodeRange, matrix: MonitorYCbCrMatrix, transfer: String, profileID: String? = nil
  ) {
    self.range = range
    self.matrix = matrix
    self.transfer = transfer
    self.profileID = profileID
  }
}

/// A borrowed pair must describe exactly the same producer frame. No pairing FIFO exists.
public struct MonitorFrameBundle: @unchecked Sendable {
  public let stamp: MonitorFrameStamp
  public let source: CVPixelBuffer
  public let output: CVPixelBuffer?
  public let sourceGeometry: MonitorGeometry
  public let outputGeometry: MonitorGeometry?
  public let sourceSignal: MonitorFrameSignal?
  public let outputSignal: MonitorFrameSignal?
  public let correspondence: MonitorCorrespondence?
  public init(
    stamp: MonitorFrameStamp, source: CVPixelBuffer, output: CVPixelBuffer? = nil,
    sourceGeometry: MonitorGeometry? = nil, outputGeometry: MonitorGeometry? = nil,
    correspondence: MonitorCorrespondence? = nil, sourceSignal: MonitorFrameSignal? = nil,
    outputSignal: MonitorFrameSignal? = nil
  ) {
    self.stamp = stamp
    self.source = source
    self.output = output
    self.sourceGeometry =
      sourceGeometry
      ?? MonitorGeometry(
        width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    self.outputGeometry = outputGeometry
    self.correspondence = correspondence
    self.sourceSignal = sourceSignal
    self.outputSignal = outputSignal
  }
}

/// Resources remain charged while a live surface or frozen snapshot holds this object.
private final class PixelBudgetOwner: NSObject {
  let releaseBudget: () -> Void
  init(_ release: @escaping () -> Void) { releaseBudget = release }
  deinit { releaseBudget() }
}
public final class MonitorOwnedFrame: @unchecked Sendable {
  public let stamp: MonitorFrameStamp
  public let pixelBuffer: CVPixelBuffer
  init(stamp: MonitorFrameStamp, pixelBuffer: CVPixelBuffer, releaseBudget: @escaping () -> Void) {
    self.stamp = stamp
    self.pixelBuffer = pixelBuffer
    CVBufferSetAttachment(
      pixelBuffer, "com.ultracam.monitor.budget" as CFString, PixelBudgetOwner(releaseBudget),
      .shouldNotPropagate)
  }
}

public enum MonitorPreviewError: Error {
  case unsupportedFormat, invalidLayout, allocationFailed, shadersUnavailable, gpuFailed
}

/// Exactly one producer buffer is borrowed by an admitted clean copy, then cleared before delivery.
private final class CleanPreviewInputLease: @unchecked Sendable {
  var buffer: CVPixelBuffer?
  init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
  func copy(reservation: Int) throws -> CVPixelBuffer {
    guard let buffer else { throw MonitorPreviewError.invalidLayout }
    return try CleanPreviewService.copy(buffer, reservation: reservation)
  }
}

/// CPU native-format owned copies work without a Metal device or shader library.
public final class CleanPreviewService: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "MonitorTools.clean", qos: .userInitiated, attributes: .concurrent)
  private let delivery = DispatchQueue(
    label: "MonitorTools.clean.delivery", qos: .userInitiated, attributes: .concurrent)
  private let fairness = MonitorFairAdmission()
  public let budget: MonitorAdmissionLedger
  public init(budget: MonitorAdmissionLedger = MonitorAdmissionLedger(maximumCleanCopyJobs: 4)) {
    self.budget = budget
  }
  @discardableResult public func offer(
    _ frame: MonitorFrameBundle, useOutput: Bool = true,
    completion: @escaping @Sendable (Result<MonitorOwnedFrame, Error>) -> Void
  ) -> Bool {
    guard fairness.mayAttempt(frame.stamp.target, capacity: budget.maximumCleanCopyJobs) else {
      return false
    }
    let input = useOutput ? (frame.output ?? frame.source) : frame.source
    // Native allocation can include larger alignment than the producer. Charge a conservative
    // aligned bound before allocating and reject any allocation exceeding that reservation.
    let bytes = Self.reservation(input)
    guard
      let admission = budget.tryAcquireClean(
        target: frame.stamp.target, generation: frame.stamp.generation, bytes: bytes)
    else {
      fairness.attempted(frame.stamp.target, admitted: false)
      return false
    }
    let slot = admission.copy
    let memory = admission.presentation
    fairness.attempted(frame.stamp.target, admitted: true)
    let stamp = frame.stamp
    let borrowed = CleanPreviewInputLease(input)
    queue.async { [delivery] in
      let result: Result<MonitorOwnedFrame, Error>
      let failedReservation: MonitorResourceLease?
      do {
        let owned = try autoreleasepool {
          MonitorOwnedFrame(
            stamp: stamp, pixelBuffer: try borrowed.copy(reservation: bytes),
            releaseBudget: { memory.release() })
        }
        result = .success(owned)
        failedReservation = nil
      } catch {
        result = .failure(error)
        // Error-only deliveries must also consume bounded capacity while a consumer is stalled.
        failedReservation = memory
      }
      // End the producer borrow and copy reservation before any consumer can block or dispose
      // its prior display image. Delivery retains owned results, still charged to the byte budget.
      borrowed.buffer = nil
      slot.release()
      delivery.async {
        defer { failedReservation?.release() }
        completion(result)
      }
    }
    return true
  }
  static func reservation(_ input: CVPixelBuffer) -> Int {
    let h = CVPixelBufferGetHeight(input)
    let planes = CVPixelBufferGetPlaneCount(input)
    let size =
      planes == 0
      ? CVPixelBufferGetBytesPerRow(input) * h
      : (0..<planes).reduce(0) {
        $0 + CVPixelBufferGetBytesPerRowOfPlane(input, $1)
          * CVPixelBufferGetHeightOfPlane(input, $1)
      }
    return max(1024 * 1024, max(CVPixelBufferGetDataSize(input), size) + 512 * h + 8192)
  }
  static func copy(_ input: CVPixelBuffer, reservation: Int) throws -> CVPixelBuffer {
    let format = CVPixelBufferGetPixelFormatType(input)
    let supported: Set<OSType> = [
      kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_32BGRA,
    ]
    guard supported.contains(format) else { throw MonitorPreviewError.unsupportedFormat }
    var result: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      // Aggregate planar bytes-per-row is not a plane alignment (and may not be a power of two).
      kCVPixelBufferBytesPerRowAlignmentKey: 64,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, CVPixelBufferGetWidth(input), CVPixelBufferGetHeight(input), format,
        attrs as CFDictionary, &result) == kCVReturnSuccess, let result
    else { throw MonitorPreviewError.allocationFailed }
    guard CVPixelBufferGetDataSize(result) <= reservation else {
      throw MonitorPreviewError.allocationFailed
    }
    guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else {
      throw MonitorPreviewError.invalidLayout
    }
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
      throw MonitorPreviewError.invalidLayout
    }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let planes = CVPixelBufferGetPlaneCount(input)
    let expectedPlanes =
      format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_422YpCbCr10 ? 0 : 2
    guard planes == expectedPlanes, planes == CVPixelBufferGetPlaneCount(result) else {
      throw MonitorPreviewError.invalidLayout
    }
    for p in 0..<max(1, planes) {
      let rows =
        planes == 0 ? CVPixelBufferGetHeight(input) : CVPixelBufferGetHeightOfPlane(input, p)
      let srcStride =
        planes == 0
        ? CVPixelBufferGetBytesPerRow(input) : CVPixelBufferGetBytesPerRowOfPlane(input, p)
      let dstStride =
        planes == 0
        ? CVPixelBufferGetBytesPerRow(result) : CVPixelBufferGetBytesPerRowOfPlane(result, p)
      let src =
        planes == 0
        ? CVPixelBufferGetBaseAddress(input) : CVPixelBufferGetBaseAddressOfPlane(input, p)
      let dst =
        planes == 0
        ? CVPixelBufferGetBaseAddress(result) : CVPixelBufferGetBaseAddressOfPlane(result, p)
      let dstRows =
        planes == 0 ? CVPixelBufferGetHeight(result) : CVPixelBufferGetHeightOfPlane(result, p)
      let width = CVPixelBufferGetWidth(input)
      let height = CVPixelBufferGetHeight(input)
      let tenBitPlanar =
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
      let is422 =
        format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
      let expectedRows = p == 0 || is422 ? height : (height + 1) / 2
      let expectedWidth = p == 0 ? width : (width + 1) / 2
      let activeBytes: Int
      if planes == 0 {
        activeBytes = format == kCVPixelFormatType_32BGRA ? width * 4 : ((width + 5) / 6) * 16
      } else {
        activeBytes = expectedWidth * (tenBitPlanar ? 2 : 1) * (p == 0 ? 1 : 2)
      }
      guard rows == dstRows, rows == expectedRows,
        planes == 0
          || (CVPixelBufferGetWidthOfPlane(input, p) == expectedWidth
            && CVPixelBufferGetWidthOfPlane(result, p) == expectedWidth),
        let src, let dst, srcStride >= activeBytes, dstStride >= activeBytes
      else { throw MonitorPreviewError.invalidLayout }
      // Compact native-format copy: row padding belongs to each allocation and is not image data.
      // In particular a padded producer plane may be wider than our owned destination plane.
      for y in 0..<rows {
        memcpy(dst.advanced(by: y * dstStride), src.advanced(by: y * srcStride), activeBytes)
        if dstStride > activeBytes {
          memset(dst.advanced(by: y * dstStride + activeBytes), 0, dstStride - activeBytes)
        }
      }
    }
    CVBufferPropagateAttachments(input, result)
    return result
  }
}

/// Metadata-only round-robin contention history; never stores a producer frame.
final class MonitorFairAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: [(MonitorTargetID, Double)] = []
  func mayAttempt(_ target: MonitorTargetID, capacity: Int = 1) -> Bool {
    guard lock.try() else { return false }
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    waiting.removeAll { now - $0.1 > 0.5 }
    let position = waiting.firstIndex(where: { $0.0 == target }) ?? waiting.count
    if position >= max(0, capacity) {
      if !waiting.contains(where: { $0.0 == target }) { waiting.append((target, now)) }
      return false
    }
    return true
  }
  func attempted(_ target: MonitorTargetID, admitted: Bool) {
    guard lock.try() else { return }
    defer { lock.unlock() }
    if admitted {
      waiting.removeAll { $0.0 == target }
    } else if !waiting.contains(where: { $0.0 == target }) {
      waiting.append((target, ProcessInfo.processInfo.systemUptime))
    }
  }
}

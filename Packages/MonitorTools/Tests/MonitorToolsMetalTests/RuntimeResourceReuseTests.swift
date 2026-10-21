import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class RuntimeResourceReuseTests: XCTestCase {
  private final class Hold: @unchecked Sendable { var result: MonitorDisplayResult? }

  func testEightHeldCompositesApplyBackpressureWithoutResettingPoolLimit() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Requires Metal") }
    let runtime = MonitorRuntime()
    let target = MonitorTargetID("resource-pool-capacity")
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    runtime.configure(target: target, generation: 1, configurationRevision: 1, configuration: config)
    let source = try image(width: 64, height: 32, value: 80)
    var held = [Hold]()
    for sequence in 1...8 {
      let result = try render(runtime, target: target, source: source, sequence: UInt64(sequence))
      XCTAssertNotNil(result.result?.decorated)
      held.append(result)
    }
    let ninth = try render(runtime, target: target, source: source, sequence: 9)
    XCTAssertNil(ninth.result?.decorated, "Held pool capacity must fall back to clean preview")
    XCTAssertNotNil(ninth.result?.clean)
    XCTAssertEqual(runtime.resourceStatistics.compositeAllocations, 8)
    XCTAssertEqual(runtime.resourceStatistics.compositePoolFailures, 1)
    held.removeAll()
    ninth.result = nil
    let recovered = try render(runtime, target: target, source: source, sequence: 10)
    XCTAssertNotNil(recovered.result?.decorated)
    XCTAssertGreaterThan(runtime.resourceStatistics.compositeReuses, 0)
    recovered.result = nil
    runtime.remove(target: target)
    let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      runtime.ledger.snapshot.retainedBytes == 0
    }, object: nil)
    wait(for: [released], timeout: 5)
  }

  func testOwned4KInputAvoidsSecondUploadAndCompositesReuseWithoutMutatingHeldFrames() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
      throw XCTSkip("Requires unified-memory Metal")
    }
    let target = MonitorTargetID("resource-reuse")
    let runtime = MonitorRuntime(sharedDevice: { device })
    let source = try image(width: 3840, height: 2160, value: 73)
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    config.zebra.thresholdIRE = 99
    runtime.configure(target: target, generation: 1, configurationRevision: 1, configuration: config)
    let first = try render(runtime, target: target, source: source, sequence: 1)
    var frozen: CVPixelBuffer? = try XCTUnwrap(first.result?.decorated?.pixelBuffer)
    first.result = nil
    let frozenValue = try firstByte(try XCTUnwrap(frozen))
    for sequence in 2...7 {
      try autoreleasepool {
        let nextSource = try image(width: 3840, height: 2160, value: UInt8(73 + sequence * 10))
        let result = try render(runtime, target: target, source: nextSource, sequence: UInt64(sequence))
        let next = try XCTUnwrap(result.result?.decorated?.pixelBuffer)
        XCTAssertNotEqual(try firstByte(next), frozenValue)
        result.result = nil
      }
    }
    XCTAssertEqual(try firstByte(try XCTUnwrap(frozen)), frozenValue,
      "Recycling must preserve a held CVPixelBuffer")
    let stats = runtime.resourceStatistics
    XCTAssertEqual(stats.cleanCopiedBytes, Int64(3840 * 2160 * 4 * 7))
    XCTAssertGreaterThan(stats.ownedInputBoundBytes, 0, "Eligible owned input must avoid duplicate staging")
    XCTAssertEqual(stats.stagingCopiedBytes, 0)
    XCTAssertGreaterThan(stats.compositeReuses, 0)
    XCTAssertLessThan(stats.compositeAllocations, 7)
    XCTAssertEqual(stats.compositePoolFailures, 0)
    runtime.remove(target: target)
    let frozenBytes = max(1024 * 1024, 1920 * 1080 * 4 + 512 * 1080 + 8192)
    let trimmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      runtime.resourceStatistics.compositePoolCapacityBytes == 0
        && runtime.ledger.snapshot.retainedBytes == frozenBytes
    }, object: nil)
    wait(for: [trimmed], timeout: 5)
    XCTAssertEqual(try firstByte(try XCTUnwrap(frozen)), frozenValue)
    frozen = nil
    let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      runtime.ledger.snapshot.retainedBytes == 0 && runtime.ledger.snapshot.reservations == 0
    }, object: nil)
    wait(for: [released], timeout: 5)
  }

  func testIneligible1080pOwnedLayoutFallsBackToStaging() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Requires Metal") }
    let runtime = MonitorRuntime()
    let target = MonitorTargetID("resource-fallback")
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    runtime.configure(target: target, generation: 1, configurationRevision: 1, configuration: config)
    let source = try image(width: 1920, height: 1080, value: 80)
    let hold = try render(runtime, target: target, source: source, sequence: 1)
    XCTAssertNotNil(hold.result?.decorated)
    XCTAssertGreaterThan(runtime.resourceStatistics.stagingCopiedBytes, 0)
    XCTAssertEqual(runtime.resourceStatistics.ownedInputBoundBytes, 0)
    hold.result = nil
    runtime.remove(target: target)
  }

  private func render(_ runtime: MonitorRuntime, target: MonitorTargetID, source: CVPixelBuffer,
                      sequence: UInt64) throws -> Hold {
    let result = Hold()
    let done = expectation(description: "monitor resource frame")
    let stamp = MonitorFrameStamp(target: target, generation: 1, sequence: sequence,
      sourcePTS: Double(sequence), hostTime: Double(sequence), configurationRevision: 1)
    XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp: stamp, source: source,
      correspondence: .identity,
      sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"))) {
      do { result.result = try $0.get() } catch { XCTFail("\(error)") }
      done.fulfill()
    })
    wait(for: [done], timeout: 20)
    XCTAssertNotNil(result.result)
    return result
  }

  private func image(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let result = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(result, [])
    memset(CVPixelBufferGetBaseAddress(result), Int32(value), CVPixelBufferGetDataSize(result))
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
  }

  private func firstByte(_ buffer: CVPixelBuffer) throws -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).load(as: UInt8.self)
  }
}

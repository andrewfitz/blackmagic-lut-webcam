import CoreMedia
import Foundation
import XCTest

private final class FrameReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@objcMembers final class ProcessedFrameChecks: XCTestCase {
  private func metadata(_ value: Int64) -> ProcessedFrameMetadata {
    ProcessedFrameMetadata(presentationTime: CMTime(value: value, timescale: 60_000),
      duration: VideoContract.fastDuration, width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  }

  private func frame(_ value: Int64, released counter: FrameReleaseCounter? = nil)
    -> ProcessedFrame<Int> {
    ProcessedFrame(payload: Int(value), metadata: metadata(value),
      onReleased: counter?.increment)
  }

  func testOneProcessedFrameHasIndependentRouteLeases() throws {
    let counter = FrameReleaseCounter()
    var source: ProcessedFrame<Int>? = frame(7, released: counter)
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-independent")
    let preview = try fanOut.addRoute(id: "preview", capacity: 2, policy: .reject)
    let camera = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)

    XCTAssertEqual(fanOut.publish(try XCTUnwrap(source))["preview"], .enqueued)
    XCTAssertEqual(preview.pendingCount, 1)
    XCTAssertEqual(camera.pendingCount, 1)
    let previewLease = try XCTUnwrap(preview.dequeue())
    let cameraLease = try XCTUnwrap(camera.dequeue())
    XCTAssertEqual(previewLease.payload, 7)
    XCTAssertEqual(cameraLease.metadata?.presentationTime, metadata(7).presentationTime)

    previewLease.release()
    XCTAssertTrue(previewLease.isReleased)
    source = nil
    XCTAssertEqual(counter.count, 0, "The camera route still owns the processed frame")
    XCTAssertEqual(cameraLease.payload, 7)
    cameraLease.release()
    XCTAssertEqual(counter.count, 1)
    cameraLease.release()
    XCTAssertEqual(counter.count, 1, "Release is idempotent")
    fanOut.close()
  }

  func testDropOldestBoundsRouteAndReleasesDroppedLease() throws {
    let counter = FrameReleaseCounter()
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-drop-oldest")
    let route = try fanOut.addRoute(id: "preview", capacity: 2, policy: .dropOldest)
    var first: ProcessedFrame<Int>? = frame(1, released: counter)
    var second: ProcessedFrame<Int>? = frame(2, released: counter)
    var third: ProcessedFrame<Int>? = frame(3, released: counter)
    XCTAssertEqual(fanOut.publish(try XCTUnwrap(first))["preview"], .enqueued)
    XCTAssertEqual(fanOut.publish(try XCTUnwrap(second))["preview"], .enqueued)
    XCTAssertEqual(fanOut.publish(try XCTUnwrap(third))["preview"], .enqueuedDroppingOldest)
    XCTAssertEqual(route.pendingCount, 2)

    first = nil
    second = nil
    third = nil
    let secondLease = try XCTUnwrap(route.dequeue())
    let thirdLease = try XCTUnwrap(route.dequeue())
    XCTAssertEqual(secondLease.payload, 2)
    XCTAssertEqual(thirdLease.payload, 3)
    XCTAssertNil(route.dequeue())
    XCTAssertEqual(counter.count, 1, "The evicted frame must release immediately")
    fanOut.close()
    XCTAssertEqual(counter.count, 1, "No pending route ownership remains after close")
    secondLease.release()
    thirdLease.release()
    XCTAssertEqual(counter.count, 3)
  }

  func testDropNewestAndRejectPreservePendingFrame() throws {
    let dropFanOut = FrameFanOut<Int>(label: "processed-frame-test-drop-newest")
    let dropRoute = try dropFanOut.addRoute(id: "preview", capacity: 1, policy: .dropNewest)
    var first: ProcessedFrame<Int>? = frame(10)
    var second: ProcessedFrame<Int>? = frame(11)
    XCTAssertEqual(dropFanOut.publish(try XCTUnwrap(first))["preview"], .enqueued)
    XCTAssertEqual(dropFanOut.publish(try XCTUnwrap(second))["preview"], .droppedNewest)
    first = nil
    second = nil
    XCTAssertEqual(try XCTUnwrap(dropRoute.dequeue()?.payload), 10)
    dropFanOut.close()

    let rejectFanOut = FrameFanOut<Int>(label: "processed-frame-test-reject")
    let rejectRoute = try rejectFanOut.addRoute(id: "camera", capacity: 1, policy: .reject)
    var accepted: ProcessedFrame<Int>? = frame(20)
    var rejected: ProcessedFrame<Int>? = frame(21)
    XCTAssertEqual(rejectFanOut.publish(try XCTUnwrap(accepted))["camera"], .enqueued)
    XCTAssertEqual(rejectFanOut.publish(try XCTUnwrap(rejected))["camera"], .rejected)
    accepted = nil
    rejected = nil
    XCTAssertEqual(try XCTUnwrap(rejectRoute.dequeue()?.payload), 20)
    rejectFanOut.close()
  }

  func testCancellationOnlyDrainsItsRoute() throws {
    let counter = FrameReleaseCounter()
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-cancel")
    let cancelled = try fanOut.addRoute(id: "preview", capacity: 2, policy: .reject)
    let remaining = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)
    var source: ProcessedFrame<Int>? = frame(30, released: counter)
    _ = fanOut.publish(try XCTUnwrap(source))
    let remainingLease = try XCTUnwrap(remaining.dequeue())
    cancelled.cancel()
    cancelled.cancel()
    XCTAssertTrue(cancelled.isCancelled)
    XCTAssertEqual(cancelled.pendingCount, 0)
    XCTAssertEqual(remainingLease.payload, 30)
    source = nil
    XCTAssertEqual(counter.count, 0)
    remainingLease.release()
    XCTAssertEqual(counter.count, 1)
    fanOut.close()
  }

  func testCloseDrainsPendingButKeepsDequeuedLeaseValid() throws {
    let counter = FrameReleaseCounter()
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-close")
    let route = try fanOut.addRoute(id: "camera", capacity: 2, policy: .reject)
    var source: ProcessedFrame<Int>? = frame(40, released: counter)
    _ = fanOut.publish(try XCTUnwrap(source))
    let dequeued = try XCTUnwrap(route.dequeue())
    source = nil
    fanOut.close()
    XCTAssertTrue(fanOut.isClosed)
    XCTAssertTrue(route.isCancelled)
    XCTAssertEqual(dequeued.payload, 40, "Teardown cannot invalidate an in-use lease")
    XCTAssertEqual(counter.count, 0)
    dequeued.release()
    XCTAssertEqual(counter.count, 1)
    fanOut.close()
  }

  func testInvalidAndDuplicateRoutesAreRejected() throws {
    let fanOut = FrameFanOut<Int>(label: "processed-frame-test-routes")
    XCTAssertThrowsError(try fanOut.addRoute(id: "", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .invalidRouteID)
    }
    XCTAssertThrowsError(try fanOut.addRoute(id: "camera", capacity: 0, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .invalidCapacity)
    }
    _ = try fanOut.addRoute(id: "camera", capacity: 1, policy: .reject)
    XCTAssertThrowsError(try fanOut.addRoute(id: "camera", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .duplicateRoute("camera"))
    }
    fanOut.close()
    XCTAssertThrowsError(try fanOut.addRoute(id: "after-close", capacity: 1, policy: .reject)) { error in
      XCTAssertEqual(error as? FrameFanOutError, .routerClosed)
    }
  }

  static let allTests = [
    ("independent route leases", testOneProcessedFrameHasIndependentRouteLeases),
    ("drop oldest bounds queues", testDropOldestBoundsRouteAndReleasesDroppedLease),
    ("drop newest and reject", testDropNewestAndRejectPreservePendingFrame),
    ("route cancellation", testCancellationOnlyDrainsItsRoute),
    ("serial teardown", testCloseDrainsPendingButKeepsDequeuedLeaseValid),
    ("route validation", testInvalidAndDuplicateRoutesAreRejected),
  ]
}

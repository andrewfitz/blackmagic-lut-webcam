import CoreMedia
import CoreVideo
import XCTest

@MainActor @objcMembers final class ProgramOutputRouteChecks: XCTestCase {
  private func feed(_ id: String) -> FeedID { FeedID(rawValue: id) }

  private func frame(_ id: FeedID, at seconds: Double) throws -> ProcessedFrame<CVPixelBuffer> {
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image else {
      throw VideoError.message("Cannot create Program test frame.")
    }
    return ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000),
      duration: VideoContract.fastDuration, width: 2, height: 2,
      pixelFormat: UInt32(kCVPixelFormatType_32BGRA)))
  }

  func testProgramRoutePublishesSelectedFeedOnlyAndCutsAtBoundary() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let consumer = try route.addConsumerRoute(capacity: 4)

    guard case .accepted = route.ingest(feedID: a, frame: try frame(a, at: 0)).decision else {
      return XCTFail("Initial selected feed should establish the program timeline")
    }
    XCTAssertNil(route.ingest(feedID: b, frame: try frame(b, at: 0.033)).fanOut["program-camera"])
    guard case .queued = route.requestCut(to: b) else {
      return XCTFail("Manual Program cut should queue")
    }
    guard case .cutApplied = route.ingest(feedID: b, frame: try frame(b, at: 0)).decision else {
      return XCTFail("Target feed should apply at its next valid frame")
    }
    XCTAssertEqual(consumer.pendingCount, 2)
  }

  func testProgramRouteReconfigurationKeepsOnlyEnabledFeeds() throws {
    let a = feed("alpha")
    let b = feed("beta")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    XCTAssertEqual(route.selectedFeedID, a)
    route.updateFeeds([b])
    XCTAssertEqual(route.selectedFeedID, b)
    XCTAssertFalse(route.hasPendingCut)
  }

  func testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(feeds: [a, b]))
    XCTAssertEqual(coordinator.virtualCameraDescriptors.map(\.kind), [.feed, .feed])
    coordinator.setOutputMode(.program)
    XCTAssertEqual(coordinator.virtualCameraDescriptors.map(\.kind), [.program])

    let start = coordinator.setProgramConsumer(true, at: 0)
    XCTAssertEqual(start, [.start(feedID: "alpha")])
    XCTAssertEqual(coordinator.activeDemandFeedIDs, Set(["alpha"]))
    let stop = coordinator.setProgramConsumer(false, at: 1)
    XCTAssertEqual(stop, [.stop(feedID: "alpha")])
    XCTAssertTrue(coordinator.activeDemandFeedIDs.isEmpty)
  }

  static let allTests = [
    ("selected feed and boundary cut", testProgramRoutePublishesSelectedFeedOnlyAndCutsAtBoundary),
    ("enabled feed reconfiguration", testProgramRouteReconfigurationKeepsOnlyEnabledFeeds),
    ("registry modes and Program demand", testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand),
  ]
}

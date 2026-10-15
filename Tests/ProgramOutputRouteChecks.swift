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
    XCTAssertEqual(consumer.pendingCount, 1,
      "A frame-boundary cut must flush stale frames queued before the cut")
    let first = try XCTUnwrap(consumer.dequeue())
    let firstTime = try XCTUnwrap(first.metadata?.presentationTime)
    first.release()
    XCTAssertEqual(consumer.pendingCount, 0)
    XCTAssertEqual(CMTimeCompare(firstTime, VideoContract.fastDuration), 0,
      "The first frame after a cut starts at the next Program timeline boundary")
  }

  func testFeedCoordinatorMutatesTheLiveProgramScheduler() throws {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [a, b], outputMode: .program))
    guard case .accepted = coordinator.ingestProgramFrame(feedID: a.id,
      frame: try frame(a.id, at: 0))?.decision else {
      return XCTFail("The initial Program source should be accepted")
    }

    coordinator.setSwitcher(SwitcherSettings(selectedFeedID: b.id, automatic: false,
      intervalSeconds: 30, strategy: .fixedInterval))
    XCTAssertEqual(coordinator.programOutput.pendingFeedID, b.id,
      "Settings and manual requests must target the scheduler used by ingest")
    guard case .cutApplied = coordinator.ingestProgramFrame(feedID: b.id,
      frame: try frame(b.id, at: 0))?.decision else {
      return XCTFail("The requested Program cut should apply at the next target frame")
    }
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

  func testEnteringProgramModeQueuesPersistedSwitcherSelection() {
    let a = FeedDescriptor(id: feed("alpha"), name: "Wide")
    let b = FeedDescriptor(id: feed("beta"), name: "Tight")
    let coordinator = FeedCoordinator(snapshot: AppSettingsSnapshot(
      feeds: [a, b], outputMode: .separateCameras,
      switcher: SwitcherSettings(selectedFeedID: a.id)))

    XCTAssertEqual(coordinator.programOutput.selectedFeedID, a.id)
    coordinator.setSwitcher(SwitcherSettings(selectedFeedID: b.id))
    coordinator.setOutputMode(.program)
    XCTAssertEqual(coordinator.programOutput.selectedFeedID, a.id)
    XCTAssertEqual(coordinator.programOutput.pendingFeedID, b.id)
  }

  func testProgramBridgePreservesImageAndTimingAndOwnsDemandLifecycle() throws {
    let source = feed("alpha")
    let route = ProgramOutputRoute(feedIDs: [source])
    let consumer = try route.addConsumerRoute(capacity: 4)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    guard let image else { return XCTFail("Program image allocation failed") }
    let timestamp = CMTime.zero
    let frame = ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
      presentationTime: timestamp, duration: VideoContract.fastDuration, width: 2,
      height: 2, pixelFormat: UInt32(kCVPixelFormatType_32BGRA)))
    var connects = 0
    var disconnects = 0
    var sent: [CMSampleBuffer] = []
    let bridge = ProgramOutputBridge(route: consumer,
      connect: { _, _ in connects += 1 },
      disconnect: { disconnects += 1 },
      send: { sample in sent.append(sample); return true })
    try bridge.setDemand(true, configuration: PipelineConfiguration(),
      passthroughFormat: kCVPixelFormatType_32BGRA)
    _ = route.ingest(feedID: source, frame: frame)
    bridge.pump()
    XCTAssertEqual(connects, 1)
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sent[0]), .zero,
      "The Program mapper starts its monotonic timeline at zero for the first source frame")
    XCTAssertEqual(CMSampleBufferGetDuration(sent[0]), VideoContract.fastDuration)
    XCTAssertEqual(CMSampleBufferGetImageBuffer(sent[0]), image)
    XCTAssertEqual(bridge.currentStatistics.delivered, 1)
    XCTAssertEqual(consumer.pendingCount, 0)

    bridge.disconnect()
    XCTAssertEqual(disconnects, 1)
    XCTAssertFalse(bridge.isDemanded)
    XCTAssertFalse(bridge.isConnected)
  }

  static let allTests = [
    ("selected feed and boundary cut", testProgramRoutePublishesSelectedFeedOnlyAndCutsAtBoundary),
    ("coordinator uses live Program scheduler", testFeedCoordinatorMutatesTheLiveProgramScheduler),
    ("enabled feed reconfiguration", testProgramRouteReconfigurationKeepsOnlyEnabledFeeds),
    ("registry modes and Program demand", testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand),
    ("program mode honors persisted selection", testEnteringProgramModeQueuesPersistedSwitcherSelection),
    ("Program bridge lifecycle and timing", testProgramBridgePreservesImageAndTimingAndOwnsDemandLifecycle),
  ]
}

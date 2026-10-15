import CoreMediaIO
import XCTest

@objcMembers final class CameraRegistryRuntimeChecks: XCTestCase {
  private func snapshot(_ devices: [VirtualCameraDescriptor], generation: UInt64 = 1)
    -> VirtualCameraRegistrySnapshot {
    VirtualCameraRegistrySnapshot(generation: generation, devices: devices)
  }

  func testPublishesStableDescriptorDevicesAndReusesRuntimeOnReconcile() throws {
    let feed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let program = VirtualCameraDescriptor.program()
    let first = snapshot([feed, program])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: first)
    XCTAssertEqual(camera.descriptors.map(\.id), [feed.id, program.id])
    XCTAssertEqual(camera.devices.count, 2)
    let feedRuntime = try XCTUnwrap(camera.runtime(for: feed.id))
    let programRuntime = try XCTUnwrap(camera.runtime(for: program.id))
    XCTAssertEqual(feedRuntime.descriptor.deviceUID, feed.deviceUID)
    XCTAssertEqual(programRuntime.descriptor.sourceStreamID, program.sourceStreamID)

    let renamed = VirtualCameraDescriptor.feed(feedID: "alpha", displayName: "Camera Alpha")
    let next = snapshot([renamed, program], generation: 2)
    try camera.reconcile(next)
    XCTAssertTrue(camera.runtime(for: renamed.id) === feedRuntime,
      "Identity changes must update metadata in place")
    XCTAssertTrue(camera.runtime(for: program.id) === programRuntime)
    XCTAssertEqual(camera.runtime(for: renamed.id)?.descriptor.displayName, "Camera Alpha")
  }

  func testDemandAndRemovalAreIndependentPerDevice() throws {
    let firstFeed = VirtualCameraDescriptor.feed(feedID: "alpha")
    let secondFeed = VirtualCameraDescriptor.feed(feedID: "beta")
    let first = snapshot([firstFeed, secondFeed])
    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registrySnapshot: first)
    let firstRuntime = try XCTUnwrap(camera.runtime(for: firstFeed.id))
    let secondRuntime = try XCTUnwrap(camera.runtime(for: secondFeed.id))
    try firstRuntime.source.startStream()
    XCTAssertEqual(firstRuntime.consumers, 1)
    XCTAssertEqual(secondRuntime.consumers, 0)

    let next = snapshot([secondFeed], generation: 2)
    try camera.reconcile(next)
    XCTAssertEqual(camera.devices.count, 2,
      "An in-use device remains published until its client releases demand")
    try firstRuntime.source.stopStream()
    camera.queue.sync { }
    XCTAssertEqual(camera.devices.count, 1)
    XCTAssertNil(camera.runtime(for: firstFeed.id))
    XCTAssertEqual(secondRuntime.consumers, 0)
  }
}

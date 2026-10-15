import Foundation
import XCTest

@objcMembers final class VirtualCameraRegistryPublishingChecks: XCTestCase {
  func testSeparateModePublishesOneStableDevicePerEnabledFeed() throws {
    let first = FeedDescriptor(id: FeedID(rawValue: "wide"), name: "Wide")
    let disabled = FeedDescriptor(id: FeedID(rawValue: "disabled"), name: "Disabled", enabled: false)
    let second = FeedDescriptor(id: FeedID(rawValue: "tight"), name: "Tight")
    let group = "group.org.ultrastudiolut.publish.\(UUID().uuidString)"
    let snapshot = VirtualCameraRegistrySnapshot.forFeeds([first, disabled, second],
      outputMode: .separateCameras, appGroupIdentifier: group)

    XCTAssertEqual(snapshot.generation, 1)
    XCTAssertEqual(snapshot.devices.map(\.feedID), ["wide", "tight"])
    XCTAssertEqual(snapshot.devices.map(\.displayName), [
      "UltraStudio LUT · Wide", "UltraStudio LUT · Tight"])
    XCTAssertEqual(Set(snapshot.devices.map(\.deviceUID)).count, 2)
    try snapshot.validate()
  }

  func testProgramModePublishesOnlyProgramAndAdvancesGeneration() throws {
    let feed = FeedDescriptor(id: .primary, name: "Primary")
    let group = "group.org.ultrastudiolut.publish.\(UUID().uuidString)"
    let current = VirtualCameraRegistrySnapshot(generation: 9, appGroupIdentifier: group,
      devices: [.feed(feedID: feed.id.rawValue)])
    let next = VirtualCameraRegistrySnapshot.forFeeds([feed], outputMode: .program,
      previous: current, appGroupIdentifier: group)

    XCTAssertEqual(next.generation, 10)
    XCTAssertEqual(next.devices, [.program(displayName: "UltraStudio LUT · Program")])
    try next.validate()
  }

  func testForeignGroupDoesNotSupplyGeneration() {
    let feed = FeedDescriptor(name: "Primary")
    let current = VirtualCameraRegistrySnapshot(generation: 99,
      appGroupIdentifier: "group.foreign", devices: [.feed(feedID: feed.id.rawValue)])
    let next = VirtualCameraRegistrySnapshot.forFeeds([feed], outputMode: .separateCameras,
      previous: current, appGroupIdentifier: VirtualCameraRegistrySnapshot.defaultAppGroupIdentifier)
    XCTAssertEqual(next.generation, 1)
  }

  func testCameraProviderLoadsPublishedFeedDevicesAtStartup() throws {
    let suiteName = "org.ultrastudiolut.tests.camera-startup.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let group = "group.org.ultrastudiolut.camera-startup.\(UUID().uuidString)"
    let store = VirtualCameraRegistryStore(appGroupIdentifier: group, defaults: defaults)
    let wide = VirtualCameraDescriptor.feed(feedID: "wide", displayName: "Wide")
    let tight = VirtualCameraDescriptor.feed(feedID: "tight", displayName: "Tight")
    try store.save(VirtualCameraRegistrySnapshot(generation: 1,
      appGroupIdentifier: group, devices: [wide, tight]))

    let camera = CameraProvider(automaticTimers: false, createNativeProvider: false,
      registryStore: store)
    XCTAssertEqual(camera.devices.count, 2)
    XCTAssertEqual(camera.descriptors.map(\.feedID), ["wide", "tight"])
    XCTAssertNotEqual(camera.device(for: wide.id)?.deviceID, camera.device(for: tight.id)?.deviceID)
    XCTAssertNotEqual(camera.descriptors[0].sourceStreamID, camera.descriptors[1].sourceStreamID)
  }
}


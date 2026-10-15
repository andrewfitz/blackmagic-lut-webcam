import Foundation
import XCTest

@MainActor @objcMembers final class RecordingModelChecks: XCTestCase {
  private final class Driver: RecordingSessionDriver {
    enum Operation: Equatable {
      case start(FeedID, RecordingConfiguration)
      case pause(FeedID)
      case resume(FeedID)
      case stop(FeedID)
    }

    var operations: [Operation] = []
    var failingFeeds = Set<FeedID>()

    func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.start(feedID, configuration))
    }

    func pauseRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.pause(feedID))
    }

    func resumeRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.resume(feedID))
    }

    func stopRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.stop(feedID))
    }
  }

  private enum TestError: Error { case failed }

  private let first = FeedID(rawValue: "feed-a")
  private let second = FeedID(rawValue: "feed-b")

  func testDefaultsExposeRequiredRecordingChoices() {
    XCTAssertEqual(RecordingCodec.allCases, [.proRes42210Bit, .hevcMain10_422])
    XCTAssertEqual(RecordingCodec.proRes42210Bit.title, "ProRes 422 10-bit")
    XCTAssertEqual(RecordingCodec.hevcMain10_422.title, "HEVC Main10 4:2:2")
    XCTAssertEqual(RecordingTimecodeMode.allCases, [.source, .recordStart, .wallClock])
    XCTAssertEqual(RecordingConfiguration().codec, .proRes42210Bit)
    XCTAssertEqual(RecordingConfiguration().timecodeMode, .source)
  }

  func testPerFeedControlsRemainIndependent() {
    let driver = Driver()
    let folder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    let model = RecordingModel(feeds: [
      RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight"),
    ], driver: driver)
    model.outputFolder = folder
    model.codec = .hevcMain10_422
    model.timecodeMode = .recordStart

    model.record(feedID: first)
    model.record(feedID: second)
    XCTAssertEqual(model.feeds.map(\.status), [.recording, .recording])
    XCTAssertEqual(driver.operations.count, 2)
    XCTAssertEqual(driver.operations[0], .start(first, model.configuration))

    model.pause(feedID: first)
    model.stop(feedID: second)
    XCTAssertEqual(model.feeds.map(\.status), [.paused, .idle])
    XCTAssertNil(model.feeds[0].error)
    XCTAssertNil(model.feeds[1].error)

    model.resume(feedID: first)
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(driver.operations.suffix(3).map { operation in
      switch operation {
      case .pause: return "pause"
      case .stop: return "stop"
      case .resume: return "resume"
      case .start: return "start"
      }
    }, ["pause", "stop", "resume"])
  }

  func testAllFeedActionsContinueAfterOneFeedError() {
    let driver = Driver()
    driver.failingFeeds = [second]
    let model = RecordingModel(feeds: [
      RecordingFeedDescriptor(id: first, name: "One"),
      RecordingFeedDescriptor(id: second, name: "Two"),
    ], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)

    model.recordAll()
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(model.feeds[1].status, .idle)
    XCTAssertNotNil(model.feeds[1].error)
    XCTAssertEqual(driver.operations.count, 1)

    model.stopAll()
    XCTAssertEqual(model.feeds[0].status, .idle)
    XCTAssertEqual(model.feeds[1].status, .idle)
    XCTAssertEqual(model.feeds[0].error, nil)
  }

  func testFolderRequirementIsReportedPerFeed() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "One")], driver: driver)

    model.record(feedID: first)

    XCTAssertEqual(model.feeds[0].status, .idle)
    XCTAssertEqual(model.feeds[0].error, RecordingUIError.outputFolderRequired.localizedDescription)
    XCTAssertTrue(driver.operations.isEmpty)
  }

  func testFeedRefreshPreservesLiveStateAndDropsRemovedFeeds() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Old")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    model.record(feedID: first)

    model.updateFeeds([
      RecordingFeedDescriptor(id: first, name: "Renamed"),
      RecordingFeedDescriptor(id: second, name: "Added"),
    ])

    XCTAssertEqual(model.feeds.map(\.id), [first, second])
    XCTAssertEqual(model.feeds[0].name, "Renamed")
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(model.feeds[1].status, .idle)
  }

  static let allTests = [
    ("recording choices", testDefaultsExposeRequiredRecordingChoices),
    ("independent feed controls", testPerFeedControlsRemainIndependent),
    ("all feed error isolation", testAllFeedActionsContinueAfterOneFeedError),
    ("folder requirement", testFolderRequirementIsReportedPerFeed),
    ("feed refresh state", testFeedRefreshPreservesLiveStateAndDropsRemovedFeeds),
  ]
}

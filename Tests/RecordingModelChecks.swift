import Foundation
import AVFoundation
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

  private final class Writer: SourceRecordingWriter {
    private(set) var started = false
    private(set) var finished = false
    var telemetry: SourceRecordingWriterTelemetry { SourceRecordingWriterTelemetry() }

    func start() throws { started = true }
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws { finished = true }
  }

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

  func testNativeDriverUsesPerFeedSourceRecorderAndReportsAudioGap() throws {
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    var configurations: [SourceRecordingConfiguration] = []
    let driver = NativeRecordingSessionDriver(capture: capture,
      recorderFactory: { configuration in
        configurations.append(configuration)
        return try SourceRecorderCore(configuration: configuration, writerFactory: { Writer() })
      })
    let first = FeedID(rawValue: "feed-a")
    let second = FeedID(rawValue: "feed-b")
    let folder = URL(fileURLWithPath: "/tmp/ultrastudio-recordings", isDirectory: true)

    try driver.startRecording(feedID: first,
      configuration: RecordingConfiguration(codec: .hevcMain10_422, outputFolder: folder))
    try driver.startRecording(feedID: second,
      configuration: RecordingConfiguration(codec: .proRes42210Bit, outputFolder: folder))

    XCTAssertEqual(configurations.count, 2)
    XCTAssertEqual(configurations.map(\ .feedID.rawValue), [first.rawValue, second.rawValue])
    XCTAssertEqual(configurations.map(\ .videoCodec), [kCMVideoCodecType_HEVC, kCMVideoCodecType_AppleProRes422HQ])
    XCTAssertTrue(configurations.allSatisfy { $0.width == 3840 && $0.height == 2160 })
    XCTAssertEqual(driver.startWarning, .rawAudioUnavailable)

    try driver.stopRecording(feedID: first)
    try driver.stopRecording(feedID: second)
  }

  static let allTests = [
    ("recording choices", testDefaultsExposeRequiredRecordingChoices),
    ("independent feed controls", testPerFeedControlsRemainIndependent),
    ("all feed error isolation", testAllFeedActionsContinueAfterOneFeedError),
    ("folder requirement", testFolderRequirementIsReportedPerFeed),
    ("feed refresh state", testFeedRefreshPreservesLiveStateAndDropsRemovedFeeds),
    ("native source recording driver", testNativeDriverUsesPerFeedSourceRecorderAndReportsAudioGap),
  ]
}

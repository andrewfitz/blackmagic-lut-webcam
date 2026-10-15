import Foundation
import XCTest

private struct FixedRecordingOutputDiskSpace: RecordingOutputDiskSpaceProviding {
  let bytes: UInt64

  func availableBytes(at directory: URL) throws -> UInt64 { bytes }
}

@objcMembers final class RecordingOutputChecks: XCTestCase {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultrastudio-recording-output-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func testPerFeedPathsAndAtomicFinalization() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, fileExtension: ".MOV",
      minimumFreeBytes: 100, diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let session = try manager.beginSession(feedID: "camera-a", sessionID: id, expectedBytes: 4)

    XCTAssertEqual(session.paths.feedDirectory.lastPathComponent, "camera-a")
    XCTAssertEqual(session.paths.finalFile.pathExtension, "mov")
    XCTAssertTrue(session.paths.finalFile.lastPathComponent.contains(id.uuidString.lowercased()))
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.finalURL.path))

    try session.append(Data([1, 2, 3, 4]))
    let finalized = try session.finish()
    XCTAssertEqual(finalized, session.finalURL)
    XCTAssertEqual(session.state, .finished)
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.temporaryURL.path))
    XCTAssertEqual(try Data(contentsOf: finalized), Data([1, 2, 3, 4]))
  }

  func testPausePreservesTemporaryFileAndSessionsAreIndependent() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let first = try manager.beginSession(feedID: "one", expectedBytes: 2)
    let second = try manager.beginSession(feedID: "two", expectedBytes: 2)

    try first.append(Data([10]))
    try first.pause()
    XCTAssertEqual(first.state, .paused)
    XCTAssertEqual(first.bytesWritten, 1)
    XCTAssertThrowsError(try first.append(Data([11]))) { error in
      XCTAssertEqual(error as? RecordingOutputError,
        .invalidState(.paused, operation: "append data"))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.temporaryURL.path))

    try second.append(Data([20]))
    _ = try second.finish()
    XCTAssertEqual(second.state, .finished)
    XCTAssertEqual(first.state, .paused)

    try first.resume()
    try first.append(Data([11]))
    _ = try first.finish()
    XCTAssertEqual(try Data(contentsOf: first.finalURL), Data([10, 11]))
  }

  func testRejectsTraversalAndEscapingSymlink() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent("ultrastudio-recording-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))

    for feedID in ["../outside", "/tmp/recording", "", ".", "..", "feed/child"] {
      XCTAssertThrowsError(try manager.makeSession(feedID: feedID)) { error in
        XCTAssertEqual(error as? RecordingOutputError, .invalidFeedID)
      }
    }
    let symlink = root.appendingPathComponent("escaped", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    XCTAssertThrowsError(try manager.makeSession(feedID: "escaped")) { error in
      XCTAssertEqual(error as? RecordingOutputError, .unsafePath)
    }
  }

  func testAdmissionRejectsInsufficientSpaceAndReleasesReservation() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 100,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 110))
    XCTAssertThrowsError(try manager.makeSession(feedID: "too-large", expectedBytes: 11)) { error in
      XCTAssertEqual(error as? RecordingOutputError,
        .insufficientDiskSpace(required: 111, available: 110))
    }

    let accepted = try manager.beginSession(feedID: "fits", expectedBytes: 10)
    _ = try accepted.finish()
    XCTAssertEqual(accepted.state, .finished)
  }

  func testSessionIDCollisionDoesNotReplaceExistingOutput() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0,
      diskSpace: FixedRecordingOutputDiskSpace(bytes: 10_000))
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let first = try manager.beginSession(feedID: "camera", sessionID: id)
    try first.append(Data([1]))
    _ = try first.finish()
    XCTAssertThrowsError(try manager.makeSession(feedID: "camera", sessionID: id)) { error in
      XCTAssertEqual(error as? RecordingOutputError, .destinationExists)
    }
    XCTAssertEqual(try Data(contentsOf: first.finalURL), Data([1]))
  }

  static let allTests = [
    ("per-feed paths and atomic finalization", testPerFeedPathsAndAtomicFinalization),
    ("pause preserves temporary file and sessions are independent", testPausePreservesTemporaryFileAndSessionsAreIndependent),
    ("reject traversal and escaping symlink", testRejectsTraversalAndEscapingSymlink),
    ("admission rejects insufficient space", testAdmissionRejectsInsufficientSpaceAndReleasesReservation),
    ("session ID collision does not replace output", testSessionIDCollisionDoesNotReplaceExistingOutput),
  ]
}

import AppKit
import Foundation

// Run as a signed, sandboxed app with the production selected-folder
// entitlement. Uses synthetic bytes only; never opens a camera or microphone.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let panel = NSOpenPanel()
panel.title = "Verify Ultracam recording folder access"
panel.prompt = "Verify folder"
panel.canChooseFiles = false
panel.canChooseDirectories = true
panel.allowsMultipleSelection = false
if let path = CommandLine.arguments.dropFirst().first {
  panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
}
guard panel.runModal() == .OK, let folder = panel.url else {
  fputs("OUTPUT_CHECK cancelled\n", stderr)
  exit(2)
}
let accessed = folder.startAccessingSecurityScopedResource()
defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
do {
  let root = folder.appendingPathComponent(".Ultracam-output-check-\(UUID().uuidString)", isDirectory: true)
  let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
  let session = try manager.beginExternalWriterSession(feedID: "Feed 1")
  let bytes = Data("Ultracam synthetic filesystem verification".utf8)
  try bytes.write(to: session.temporaryURL)
  let final = try session.finish()
  guard try Data(contentsOf: final) == bytes,
    !FileManager.default.fileExists(atPath: session.temporaryURL.path),
    final.lastPathComponent.hasPrefix("Feed 1_") else {
    throw RecordingOutputError.ioFailure("Output did not finalize correctly.")
  }
  print("OUTPUT_CHECK PASS createDirectory=true write=true finalize=true readback=true physicalCapture=false")
  print("OUTPUT_CHECK root=\(root.path)")
  print("OUTPUT_CHECK filename=\(final.lastPathComponent)")
} catch {
  fputs("OUTPUT_CHECK FAIL \(error.localizedDescription)\n", stderr)
  exit(1)
}

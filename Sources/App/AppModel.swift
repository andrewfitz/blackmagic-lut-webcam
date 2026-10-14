import AppKit
import Observation
import UniformTypeIdentifiers

struct InputDevice: Identifiable {
  let id: String
  let name: String
  let modes: String
}

@MainActor @Observable
final class AppModel {
  var devices: [InputDevice] = []
  var selectedDevice = ""
  var configuration = PipelineConfiguration()
  var gamut = "S-Gamut3.Cine / S-Log3"
  var lutTitle = "No LUT loaded"
  var lutLoaded = false
  var running = false
  var loading = false
  var update = CaptureUpdate(message: "Select the UltraStudio input and start the feed. LUT loading is optional.")
  let installer = ExtensionInstaller()
  let previewRenderer: VideoPreviewRenderer
  private let capture: CaptureController

  init() {
    let renderer = VideoPreviewRenderer()
    previewRenderer = renderer
    capture = CaptureController(previewRenderer: renderer)
    capture.onUpdate = { [weak self] update in
      MainActor.assumeIsolated {
        self?.update = update
        if update.stopped { self?.running = false }
      }
    }
    refresh()
  }

  func refresh() {
    do {
      self.devices = try UDLBackend.devices().map { device in
        let modes = device.modes.filter { $0.width == 3840 && $0.height == 2160 }
        let rates = Set(modes.map { String(format: "%.2f", 1 / $0.frameDuration.seconds) }).sorted().joined(separator: ", ")
        return InputDevice(id: device.identifier, name: device.name,
          modes: rates.isEmpty ? "No 4K capture modes" : "4K 10-bit SDK capture · \(rates) fps")
      }
    } catch { devices = []; update.message = error.localizedDescription }
    if !self.devices.contains(where: { $0.id == selectedDevice }) {
      selectedDevice = self.devices.first?.id ?? ""
    }
  }

  func chooseLUT() {
    let panel = NSOpenPanel()
    panel.title = "Choose an FX3 log-to-Rec.709 LUT"
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loading = true
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1024 * 1024 else {
        throw VideoError.message("LUT file exceeds 32 MB.")
      }
      let cube = try CubeLUT(text: String(contentsOf: url, encoding: .utf8), fallbackTitle: url.deletingPathExtension().lastPathComponent)
      capture.load(cube) { [weak self] result in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.loading = false
          switch result {
          case .success:
            self.lutLoaded = true
            self.configuration.applyLUT = true
            self.lutTitle = "\(cube.title) · \(cube.dimension)³"
            self.update.message = "LUT loaded. Confirm it expects \(self.gamut) and outputs Rec.709."
          case .failure(let error): self.update.message = error.localizedDescription
          }
        }
      }
    } catch { loading = false; update.message = error.localizedDescription }
  }

  func start() {
    running = true
    update.message = "Opening UltraStudio…"
    var snapshot = configuration
    snapshot.applyLUT = snapshot.applyLUT && lutLoaded
    capture.start(deviceID: selectedDevice, configuration: snapshot)
  }
  func stop() { running = false; capture.stop() }
}

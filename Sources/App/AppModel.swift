import AppKit
import AVFoundation
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
  var update = CaptureUpdate(message: "Select the UltraStudio input and load a log-to-Rec.709 .cube LUT.")
  let installer = ExtensionInstaller()
  private let capture = CaptureController()

  init() {
    capture.onUpdate = { [weak self] update in
      MainActor.assumeIsolated {
        self?.update = update
        if update.stopped { self?.running = false }
      }
    }
    refresh()
  }

  func refresh() {
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    self.devices = devices.filter {
      let name = $0.localizedName.lowercased()
      return name.contains("blackmagic") || name.contains("ultrastudio")
    }.map { device in
      let modes = Set(device.formats.compactMap { format -> String? in
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard size.width == 3840, size.height == 2160 else { return nil }
        return VideoContract.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
      }).sorted().joined(separator: ", ")
      return InputDevice(id: device.uniqueID, name: device.localizedName,
        modes: modes.isEmpty ? "No 4K formats advertised" : "4K driver formats: \(modes)")
    }
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
    Task {
      let allowed = await AVCaptureDevice.requestAccess(for: .video)
      guard allowed else {
        running = false
        update.message = "Camera access is denied. Enable UltraStudio LUT in System Settings → Privacy & Security → Camera."
        return
      }
      guard running else { return }
      capture.start(deviceID: selectedDevice, configuration: configuration)
    }
  }
  func stop() { capture.stop() }
}

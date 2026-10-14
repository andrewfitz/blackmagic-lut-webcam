import SwiftUI

@main
struct UltraStudioLUTApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup("UltraStudio LUT") {
      ContentView(model: model)
        .frame(minWidth: 840, minHeight: 690)
    }
    .defaultSize(width: 1050, height: 830)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appTermination) {
        Button("Quit UltraStudio LUT") {
          model.stop()
          NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
      }
    }
  }
}

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("UltraStudio LUT").font(.largeTitle.bold())
          Text("FX3 log in. Your look out.").foregroundStyle(.secondary)
        }
        Spacer()
        Label(model.running ? "LIVE" : "STOPPED", systemImage: model.running ? "circle.fill" : "circle")
          .foregroundStyle(model.running ? .green : .secondary)
      }
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Picker("Input", selection: $model.selectedDevice) {
            if model.devices.isEmpty { Text("No UltraStudio detected").tag("") }
            ForEach(model.devices) { Text($0.name).tag($0.id) }
          }
          Text(model.devices.first(where: { $0.id == model.selectedDevice })?.modes ?? "Connect UltraStudio and install Blackmagic Desktop Video.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
        Picker("Source rate", selection: $model.configuration.inputFast) {
          Text("29.97 fps").tag(false)
          Text("59.94 fps").tag(true)
        }.frame(width: 225)
      }.disabled(model.running)

      GroupBox("Processing — in this order") {
        HStack(alignment: .top, spacing: 24) {
          pipelineToggle("1  Apply LUT", detail: model.lutLoaded ? "Full-resolution, floating-point processing" : "Optional · load a LUT to enable", value: $model.configuration.applyLUT)
            .disabled(!model.lutLoaded)
          pipelineToggle("2  Downscale", detail: "4K → 1080p · Lanczos", value: $model.configuration.downscale)
          pipelineToggle("3  Color format", detail: "4:2:2 10-bit → 4:2:0 8-bit", value: $model.configuration.convertTo420)
          pipelineToggle("4  Frame rate", detail: "59.94 → 29.97 fps", value: $model.configuration.reduceFrameRate)
        }.padding(10)
      }.disabled(model.running || model.loading)

      HStack {
        Button("Load .cube LUT…", systemImage: "folder", action: model.chooseLUT)
          .disabled(model.running || model.loading)
        Text(model.lutTitle).font(.callout).textSelection(.enabled)
        Spacer()
        Picker("LUT input", selection: $model.gamut) {
          Text("S-Gamut3.Cine / S-Log3").tag("S-Gamut3.Cine / S-Log3")
          Text("S-Gamut3 / S-Log3").tag("S-Gamut3 / S-Log3")
        }.frame(width: 300).disabled(model.running)
      }
      Text("Use a LUT that converts the selected log gamut to Rec.709. No extra log transform is added. With LUT off, the output stays ungraded.")
        .font(.caption).foregroundStyle(.secondary)

      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(.black)
        VideoPreview(renderer: model.previewRenderer).padding(2)
        if !model.update.previewDelivered {
          VStack(spacing: 12) {
            Image(systemName: "video.badge.waveform").font(.system(size: 40))
            Text("Processed feed preview")
            Text("Select UltraStudio LUT as the camera in Zoom.").font(.caption)
          }.foregroundStyle(.white.opacity(0.65))
        }
      }.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.configuration.outputLabel).font(.headline)
          Text(model.update.input).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(model.update.outputFPS, specifier: "%.2f") fps · \(model.update.displayedFrames) displayed · \(model.update.processingMS, specifier: "%.1f") ms\nDrops: source \(model.update.sourceDrops) · capture \(model.update.captureDrops) · pool \(model.update.poolDrops) · camera \(model.update.cameraDrops) · preview \(model.update.previewDrops)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        if model.running {
          Button("Stop", systemImage: "stop.fill", action: model.stop).buttonStyle(.borderedProminent).tint(.red)
        } else {
          Button("Start feed", systemImage: "play.fill", action: model.start).buttonStyle(.borderedProminent)
            .disabled(model.selectedDevice.isEmpty || model.loading)
        }
      }
      Text(model.update.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      Label(model.update.cameraMessage, systemImage: model.update.cameraOutputActive ? "video.fill" : "video.slash")
        .font(.caption).foregroundStyle(model.update.cameraOutputActive ? .green : .secondary)
      Divider()
      HStack {
        Button("Install camera", action: model.installer.install).disabled(model.installer.pending || model.running)
        Button("Remove camera", action: model.installer.uninstall).disabled(model.installer.pending || model.running)
        Text(model.installer.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }.padding(24)
  }

  private func pipelineToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(title, isOn: value).toggleStyle(.checkbox).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

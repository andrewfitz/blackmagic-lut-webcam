import AppKit
import SwiftUI

@main
struct UltraStudioLUTApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    // A single window keeps the main native video layer attached to one view.
    Window("UltraStudio LUT", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 850, minHeight: 590)
    }
    .defaultSize(width: 1080, height: 640)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appTermination) {
        Button("Quit UltraStudio LUT") {
          model.saveSettings()
          model.stop()
          NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
      }
    }

    MenuBarExtra {
      MenuBarInterface(model: model)
    } label: {
      MenuBarStatusIcon(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

struct ContentView: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 18) {
        FeedPreview(model: model, compact: false)
          .frame(maxWidth: .infinity)
        FeedControls(model: model)
          .frame(width: 285)
      }
      Divider()
      PipelineControls(model: model, compact: false)
      LUTControls(model: model, compact: false)
      CameraInstallationControls(model: model)
    }
    .padding(20)
  }
}

struct FeedPreview: View {
  let model: AppModel
  var compact: Bool

  var body: some View {
    ZStack {
      Color.black
      if model.previewEnabled {
        VideoPreview(renderer: compact ? model.miniPreviewRenderer : model.previewRenderer)
      }
      if !model.previewEnabled || !model.previewReady {
        VStack(spacing: 9) {
          Image(systemName: model.previewEnabled ? "video" : "video.slash")
            .font(.system(size: compact ? 24 : 34, weight: .light))
          Text(model.previewEnabled ? (model.running ? "Waiting for video" : "Feed stopped") : "Preview off")
            .font(compact ? .caption : .callout)
          if !model.previewEnabled && model.running {
            Text("Feed continues with preview off")
              .font(.caption).foregroundStyle(.white.opacity(0.5))
          }
        }
        .foregroundStyle(.white.opacity(0.7))
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10))
    .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 10).strokeBorder(.white.opacity(0.08)))
    .accessibilityLabel(compact ? "Menu bar feed preview" : "Feed preview")
  }
}

struct FeedControls: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        FeedStateLabel(model: model)
        Spacer()
        StartStopButton(model: model)
      }
      PipelineEnableControl(model: model)
      Toggle("Video preview", isOn: $model.previewEnabled)
        .toggleStyle(.switch).controlSize(.small)
        .help("Display the processed feed. Turning preview off does not stop camera output.")
      Divider()
      HStack(spacing: 6) {
        Picker("Input", selection: $model.selectedDevice) {
          if model.devices.isEmpty { Text("No device detected").tag("") }
          ForEach(model.devices) { Text($0.name).tag($0.id) }
        }
        .labelsHidden().disabled(model.running)
        .accessibilityLabel("Capture input")
        Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).disabled(model.running)
          .help("Refresh capture devices").accessibilityLabel("Refresh capture devices")
      }
      FeedMetadata(model: model)
      FeedDiagnostics(model: model, compact: false)
    }
  }
}

struct FeedStateLabel: View {
  let model: AppModel

  var body: some View {
    let live = model.running && model.update.pipelineEnabledApplied != nil
    Label(live ? "Live" : model.running ? "Starting…" : "Stopped",
      systemImage: live ? "circle.fill" : model.running ? "circle.dotted" : "circle")
      .font(.callout.weight(.semibold))
      .foregroundStyle(live ? .green : .secondary)
  }
}

struct StartStopButton: View {
  let model: AppModel

  var body: some View {
    Button(model.running ? "Stop feed" : "Start feed", systemImage: model.running ? "stop.fill" : "play.fill") {
      if model.running { model.stop() } else { model.start() }
    }
    .buttonStyle(.borderedProminent)
    .tint(model.running ? .red : .accentColor)
    .disabled(!model.running && (model.selectedDevice.isEmpty || model.loading))
  }
}

struct PipelineEnableControl: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle("Processing enabled", isOn: $model.pipelineEnabled)
        .toggleStyle(.switch).controlSize(.small)
        .help("Turn off to bypass all processing and pass through the complete original feed.")
      AppliedPipelineState(model: model)
    }
  }
}

// Read applied state separately from the requested checkbox: starting and
// changing settings must never claim the next pipeline is already on the wire.
struct AppliedPipelineState: View {
  let model: AppModel

  var body: some View {
    let applied = model.update.pipelineEnabledApplied
    let established = model.running && applied != nil
    let transitioning = established && applied != model.pipelineEnabled
    Label(
      !established ? (model.pipelineEnabled ? "Processing selected" : "Complete bypass selected")
        : transitioning ? "Applying change…"
        : applied == true ? "Processing active" : "Complete bypass active",
      systemImage: established && !transitioning ? (applied == true ? "slider.horizontal.3" : "arrow.right") : "circle.dotted")
      .font(.caption)
      .foregroundStyle(established && !transitioning ? (applied == true ? .green : .orange) : .secondary)
  }
}

struct FeedMetadata: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MetadataRow(title: "INPUT", value: model.running ? model.update.input : "Not detected")
      MetadataRow(title: "OUTPUT", value: model.running && !model.update.output.isEmpty ? model.update.output : "Not streaming")
    }
  }
}

private struct MetadataRow: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      Text(value).font(.caption.monospacedDigit()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
}

// Frequent counters invalidate only this subtree, never the native video view
// or the controls. Video frames themselves stay outside SwiftUI observation.
struct FeedDiagnostics: View {
  let model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if model.running {
        Text("\(model.update.outputFPS, specifier: "%.2f") fps · \(model.update.processingMS, specifier: "%.1f") ms")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        if !compact {
          Text("Drops  source \(model.update.sourceDrops) · capture \(model.update.captureDrops)\nBuffers \(model.update.poolDrops) · camera \(model.update.cameraDrops) · preview \(model.update.previewDrops)")
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      Text(model.update.message).font(.caption).fixedSize(horizontal: false, vertical: true)
      Label(model.update.cameraMessage, systemImage: model.update.cameraOutputActive ? "video.fill" : "video.slash")
        .font(.caption2).foregroundStyle(model.update.cameraOutputActive ? .green : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct PipelineControls: View {
  @Bindable var model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      Text("Processing order").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      if compact {
        controls
      } else {
        HStack(alignment: .top, spacing: 18) { controls }
      }
    }
    .disabled(model.loading)
  }

  @ViewBuilder private var controls: some View {
    PipelineToggle(title: "1  LUT", detail: model.lutLoaded ? model.lutTitle : "Load a .cube to enable", value: $model.configuration.applyLUT, compact: compact)
      .disabled(!model.lutLoaded)
    PipelineToggle(title: "2  Downscale", detail: "1080p · Lanczos", value: $model.configuration.downscale, compact: compact)
    PipelineToggle(title: "3  Color format", detail: "4:2:0 · 8-bit", value: $model.configuration.convertTo420, compact: compact)
    PipelineToggle(title: "4  Frame rate", detail: "Limit to 29.97 fps", value: $model.configuration.reduceFrameRate, compact: compact)
  }
}

private struct PipelineToggle: View {
  let title: String
  let detail: String
  @Binding var value: Bool
  var compact: Bool

  var body: some View {
    if compact {
      HStack {
        Toggle(title, isOn: $value).toggleStyle(.checkbox)
        Spacer(minLength: 8)
        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    } else {
      VStack(alignment: .leading, spacing: 5) {
        Toggle(title, isOn: $value).toggleStyle(.checkbox).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LUTControls: View {
  @Bindable var model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button("Load LUT…", systemImage: "folder", action: model.chooseLUT)
          .disabled(model.loading)
        if model.loading { ProgressView().controlSize(.small) }
        if !compact {
          Text(model.lutTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
          Spacer()
        }
      }
      Picker("LUT input", selection: $model.gamut) {
        Text("S-Gamut3.Cine / S-Log3").tag("S-Gamut3.Cine / S-Log3")
        Text("S-Gamut3 / S-Log3").tag("S-Gamut3 / S-Log3")
      }
      .font(.caption)
      .frame(maxWidth: compact ? .infinity : 380, alignment: .leading)
      .help("Declared input expected by the LUT. No additional log transform is applied.")
      if !compact {
        Text("LUT first, then scale, color format and frame rate. Complete bypass preserves the original feed.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct CameraInstallationControls: View {
  let model: AppModel

  var body: some View {
    DisclosureGroup("Virtual camera installation") {
      HStack(alignment: .center, spacing: 10) {
        Button("Install camera", action: model.installer.install).disabled(model.installer.pending || model.running)
        Button("Remove camera", action: model.installer.uninstall).disabled(model.installer.pending || model.running)
        Text(model.installer.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }.padding(.top, 6)
    }.font(.caption).foregroundStyle(.secondary)
  }
}

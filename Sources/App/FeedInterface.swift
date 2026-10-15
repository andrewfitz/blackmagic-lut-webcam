import AppKit
import SwiftUI

struct ContentView: View {
  let model: AppModel
  @State private var recordingModel: RecordingModel

  init(model: AppModel) {
    self.model = model
    _recordingModel = State(initialValue: model.recordingModel)
  }

  private var recordingFeeds: [RecordingFeedDescriptor] {
    model.feedDescriptors.map { RecordingFeedDescriptor(id: $0.id, name: $0.name) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 18) {
          VStack(spacing: 8) {
            HStack {
              Text("Output preview").font(.callout.weight(.medium))
              Spacer()
              PreviewVisibilityControl(model: model)
            }
            FeedPreview(model: model, compact: false)
            PreviewErrorNotice(model: model)
          }
          .frame(maxWidth: .infinity)
          FeedControls(model: model).frame(width: 292)
        }
        ControlPanel {
          RecordingControls(model: recordingModel, feeds: recordingFeeds)
        }
        ControlPanel { MultiCameraControls(model: model) }
        ControlPanel { PipelineControls(model: model, compact: false) }
        ControlPanel { LUTControls(model: model, compact: false) }
        FeedNotice(model: model)
      }
      .padding(16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

struct ControlPanel<Content: View>: View {
  private let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(11)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
  }
}

struct FeedPreview: View {
  let model: AppModel
  var compact: Bool

  var body: some View {
    // The base shape owns layout. The native video view must not contribute an
    // unconstrained ideal height or stretch a 16:9 image in a flexible stack.
    Rectangle().fill(.black)
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .overlay {
        ZStack {
          if model.previewEnabled {
            VideoPreview(renderer: compact ? model.miniPreviewRenderer : model.previewRenderer)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if !model.previewEnabled || !model.previewReady {
            PreviewPlaceholder(model: model, compact: compact)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
      .accessibilityLabel(compact ? "Menu bar feed preview" : "Feed preview")
  }
}

private struct PreviewPlaceholder: View {
  let model: AppModel
  let compact: Bool

  var body: some View {
    VStack(spacing: compact ? 7 : 10) {
      Image(systemName: model.previewEnabled ? "video" : "eye.slash")
        .font(.system(size: compact ? 23 : 30, weight: .light))
        .foregroundStyle(.white.opacity(0.4))
      Text(!model.previewEnabled ? "Preview hidden" : model.running ? "Waiting for video" : model.automaticFeedEnabled ? "Waiting for a camera app" : "Feed stopped")
        .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
        .foregroundStyle(.white.opacity(0.8))
      if !compact {
        Text(!model.previewEnabled
          ? (model.running && model.update.cameraOutputActive ? "Camera output continues with your selected settings." : "Show preview to monitor the output.")
          : model.running ? "The preview appears when a supported HDMI signal arrives." : model.automaticFeedEnabled
            ? "Open UltraStudio LUT in Zoom or another camera app to start the feed." : "Start the feed to view the HDMI input.")
          .font(.caption).foregroundStyle(.white.opacity(0.45))
          .multilineTextAlignment(.center).padding(.horizontal, 24)
      }
    }
  }
}

struct PreviewVisibilityControl: View {
  @Bindable var model: AppModel

  var body: some View {
    Toggle(isOn: $model.previewEnabled) {
      Label("Preview", systemImage: model.previewEnabled ? "eye" : "eye.slash")
        .font(.caption)
    }
    .toggleStyle(.switch).controlSize(.mini)
    .fixedSize()
    .help("Show or hide both previews. Camera output continues independently. ⇧⌘P")
    .accessibilityLabel("Video preview")
  }
}

struct PreviewErrorNotice: View {
  let model: AppModel

  var body: some View {
    if let error = model.update.previewError {
      HStack(alignment: .top, spacing: 8) {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption).foregroundStyle(.orange)
          .lineLimit(3).help(error).textSelection(.enabled)
        Spacer(minLength: 4)
        Button("Retry preview", action: model.resetPreview)
          .controlSize(.small).disabled(!model.previewEnabled)
          .help("Restart preview rendering. Camera output continues.")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct CameraConnectionLabel: View {
  let model: AppModel

  var body: some View {
    let connected = model.running && model.update.cameraOutputActive
    Label(connected ? "Camera connected" : !model.installer.canRequestChanges || model.running
      ? "Camera unavailable" : "Camera not connected", systemImage: connected ? "video.fill" : "video.slash")
      .font(.caption2).foregroundStyle(connected ? Color.green : Color.secondary)
      .help(model.installer.unavailableReason ?? model.update.cameraMessage)
  }
}

struct FeedControls: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ControlPanel {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(model.selectedFeedName).font(.caption2).foregroundStyle(.secondary)
              FeedStateLabel(model: model)
            }
            Spacer()
            StartStopButton(model: model)
          }
          Divider()
          PipelineEnableControl(model: model)
          AutomaticFeedControl(model: model)
        }
      }
      ControlPanel {
        VStack(alignment: .leading, spacing: 14) {
          InputDeviceControl(model: model)
          Divider()
          FeedMetadata(model: model)
        }
      }
      ControlPanel { CameraOutputControls(model: model) }
      DisclosureGroup("Diagnostics") {
        FeedDiagnostics(model: model, compact: false).padding(.top, 8)
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct MultiCameraControls: View {
  let model: AppModel
  @State private var nameDraft = ""

  private var selectedFeedBinding: Binding<FeedID> {
    Binding(get: { model.selectedFeedID }, set: { _ = model.selectFeed($0) })
  }

  private var outputModeBinding: Binding<FeedOutputMode> {
    Binding(get: { model.outputMode }, set: { model.setOutputMode($0) })
  }

  private var strategyBinding: Binding<SwitcherStrategy> {
    Binding(get: { model.switcherSettings.strategy }, set: {
      var settings = model.switcherSettings
      settings.strategy = $0
      model.updateSwitcher(settings)
    })
  }

  private var autoSwitchBinding: Binding<Bool> {
    Binding(get: { model.switcherSettings.automatic }, set: {
      var settings = model.switcherSettings
      settings.automatic = $0
      model.updateSwitcher(settings)
    })
  }

  private var intervalBinding: Binding<Double> {
    Binding(get: { model.switcherSettings.intervalSeconds }, set: {
      var settings = model.switcherSettings
      settings.intervalSeconds = $0
      model.updateSwitcher(settings)
    })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Cameras").font(.callout.weight(.medium))
        Spacer()
        Button(action: { _ = model.addFeed() }) {
          Label("Add", systemImage: "plus")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .disabled(!model.canEditFeedTopology)
      }

      HStack(spacing: 6) {
        Picker("Feed", selection: selectedFeedBinding) {
          ForEach(model.feedDescriptors) { feed in
            Text(feed.name).tag(feed.id)
          }
        }
        .labelsHidden().frame(maxWidth: .infinity)
        .disabled(!model.canEditFeedTopology)
        Button {
          _ = model.removeFeed(model.selectedFeedID)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .disabled(!model.canEditFeedTopology || model.feedDescriptors.count < 2)
        .help("Remove selected feed")
      }

      TextField("Feed name", text: $nameDraft)
        .textFieldStyle(.roundedBorder)
        .disabled(!model.canEditFeedTopology)
        .onAppear { nameDraft = model.selectedFeedName }
        .onChange(of: model.selectedFeedID) { _, _ in nameDraft = model.selectedFeedName }
        .onSubmit {
          _ = model.renameFeed(model.selectedFeedID, name: nameDraft)
          nameDraft = model.selectedFeedName
        }

      Picker("Output", selection: outputModeBinding) {
        Text("Separate cameras").tag(FeedOutputMode.separateCameras)
        Text("Program / switcher").tag(FeedOutputMode.program)
      }
      .disabled(model.running || !model.canEditFeedTopology)

      if model.outputMode == .program {
        Divider()
        Text("Program switcher").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Toggle("Automatic switching", isOn: autoSwitchBinding)
          .toggleStyle(.switch).controlSize(.mini)
        Picker("Strategy", selection: strategyBinding) {
          Text("Manual").tag(SwitcherStrategy.manual)
          Text("Fixed interval").tag(SwitcherStrategy.fixedInterval)
          Text("Dynamic analysis (later)").tag(SwitcherStrategy.dynamicAnalysis)
        }
        .disabled(!model.switcherSettings.automatic)
        if model.switcherSettings.automatic && model.switcherSettings.strategy == .fixedInterval {
          HStack {
            Text("Every \(String(format: "%.1f", model.switcherSettings.intervalSeconds))s")
              .font(.caption2).foregroundStyle(.secondary)
            Slider(value: intervalBinding, in: 1...30, step: 0.5)
          }
        }
        HStack(spacing: 5) {
          ForEach(model.feedDescriptors.filter(\.enabled)) { feed in
            Button(feed.name) { _ = model.requestProgramCut(to: feed.id) }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(feed.id == model.switcherSelectedFeedID ? .accentColor : .secondary)
          }
        }
        if model.switcherStatus == "Coming later." {
          Text(model.switcherStatus).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct InputDeviceControl: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Capture input").font(.caption.weight(.medium)).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        if model.devices.isEmpty {
          Text("No UltraStudio detected").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Picker("Capture input", selection: $model.selectedDevice) {
            ForEach(model.devices) { Text($0.name).tag($0.id) }
          }
          .labelsHidden().frame(maxWidth: .infinity)
          .help(model.running ? "Stop the feed to choose another input." : "Choose the Blackmagic capture device.")
        }
        Button(action: model.refresh) { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
          .buttonStyle(.borderless)
          .help("Refresh capture devices").accessibilityLabel("Refresh capture devices")
      }
      .disabled(model.running)
    }
  }
}

struct FeedStateLabel: View {
  let model: AppModel

  private var label: String {
    guard model.running else { return model.automaticFeedEnabled ? "Automatic · idle" : "Stopped" }
    if model.update.pipelineEnabledApplied != nil { return "Live" }
    if model.update.message.hasPrefix("Opening") { return "Connecting" }
    if model.update.sourceDuration != nil { return "Ready" }
    return "Waiting for HDMI"
  }

  var body: some View {
    let live = model.running && model.update.pipelineEnabledApplied != nil
    HStack(spacing: 6) {
      Circle().fill(live ? Color.green : Color.secondary.opacity(0.55)).frame(width: 6, height: 6)
      Text(label).font(.caption.weight(.semibold))
    }
    .accessibilityElement(children: .combine)
    .help(model.update.message)
  }
}

struct StartStopButton: View {
  let model: AppModel

  var body: some View {
    if model.automaticFeedEnabled {
      if model.cameraRequested && !model.running {
        Button("Retry feed", action: model.retryAutomaticFeed)
          .disabled(model.loading || !model.canStartFeed)
      }
    } else {
      Button(model.running ? "Stop feed" : "Start feed", systemImage: model.running ? "stop.fill" : "play.fill") {
        if model.running { model.stop() } else { model.start() }
      }
      .buttonStyle(.borderedProminent)
      .tint(model.running ? .secondary : .accentColor)
      .controlSize(.regular)
      .disabled(!model.running && !model.canStartFeed)
      .help(model.running ? "Stop capture and camera output. ⌘↩" : model.loading ? "Waiting for the saved LUT to finish loading." : "Start capture using your selected settings. ⌘↩")
    }
  }
}

struct AutomaticFeedControl: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle("Start when camera is in use", isOn: $model.automaticFeedEnabled)
        .toggleStyle(.switch).controlSize(.mini).font(.caption)
        .help("Automatically start for Zoom or another camera app, then stop capture and GPU work when the last app closes the camera. Keep UltraStudio LUT open in the menu bar. Turn off to manage the feed manually.")
      if model.automaticFeedEnabled {
        Text(model.automaticFeedStatus).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct PipelineEnableControl: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle("Processing", isOn: $model.pipelineEnabled)
        .font(.callout.weight(.medium)).toggleStyle(.switch).controlSize(.small)
        .help("Turn off for complete bypass: original resolution, color, pixels and frame rate. Your effect selections stay saved. ⇧⌘B")
      AppliedPipelineState(model: model)
    }
  }
}

struct AppliedPipelineState: View {
  let model: AppModel

  var body: some View {
    let applied = model.update.pipelineEnabledApplied
    let established = model.running && applied != nil
    let transitioning = established && applied != model.pipelineEnabled
    Label(!established ? (model.pipelineEnabled ? "Effects selected" : "Complete bypass selected")
      : transitioning ? "Applying change…" : applied == true ? "Effects active" : "Complete bypass active",
      systemImage: established && !transitioning ? (applied == true ? "checkmark.circle.fill" : "arrow.right") : "circle")
      .font(.caption)
      .foregroundStyle(established && !transitioning ? (applied == true ? Color.green : Color.orange) : Color.secondary)
      .accessibilityElement(children: .combine)
  }
}

struct FeedMetadata: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MetadataRow(title: "Input", value: model.running ? model.update.input : "Not detected")
      MetadataRow(title: "Output", value: model.running && !model.update.output.isEmpty ? model.update.output : "Not streaming")
      Divider()
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("Timecode", systemImage: "clock")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text(model.update.timecode ?? "—")
          .font(.system(.caption, design: .monospaced).weight(.medium))
          .foregroundStyle(model.update.timecode == nil ? .secondary : .primary)
          .textSelection(.enabled)
      }
      AudioLevelMeter(model: model)
    }
  }
}

private struct MetadataRow: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 11.5).monospacedDigit())
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }
}

// Only this details view observes frequent counters; native video frames do not
// flow through SwiftUI state. Keep rates tabular so readings do not shift layout.
struct FeedDiagnostics: View {
  let model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if model.running {
        LabeledContent("Delivered", value: String(format: "%.2f fps", model.update.outputFPS))
        LabeledContent("Processing", value: String(format: "%.2f ms", model.update.processingMS))
        LabeledContent("Video bitrate", value: formattedVideoBitrate(model.update.videoBitrateMbps))
        LabeledContent("Video drops", value: model.update.videoDrops.formatted())
        Divider()
        LabeledContent("Audio", value: audioFormat(model.update))
        LabeledContent("Audio bitrate", value: formattedAudioBitrate(model.update.audioBitrateKbps))
        LabeledContent("Audio packets", value: model.update.audioPackets.formatted())
        LabeledContent("Audio samples", value: model.update.audioSamples.formatted())
        LabeledContent("Audio drops", value: model.update.audioDrops.formatted())
        if !compact {
          Divider()
          LabeledContent("Source gaps", value: "\(model.update.sourceDrops)")
          LabeledContent("Capture admission", value: "\(model.update.captureDrops)")
          LabeledContent("Output buffers", value: "\(model.update.poolDrops)")
          LabeledContent("Camera transport", value: "\(model.update.cameraDrops)")
          LabeledContent("Preview", value: "\(model.update.previewDrops)")
          Text("Native renderer totals include prior runs. Intentional frame-rate reduction is excluded.")
            .font(.caption2).foregroundStyle(.tertiary)
        }
      }
      Text(model.update.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Text(model.update.cameraMessage).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if let error = model.update.previewError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
    }
    .font(.caption.monospacedDigit())
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func audioFormat(_ update: CaptureUpdate) -> String {
    guard update.audioPresent else { return "No embedded audio" }
    let channels = update.audioChannels > 0 ? "\(update.audioChannels) ch" : "Audio"
    let rate = update.audioSampleRate > 0 ? " · \(formatSampleRate(update.audioSampleRate))" : ""
    return channels + rate
  }

  private func formatSampleRate(_ rate: Int) -> String {
    if rate >= 1_000 { return String(format: "%.1f kHz", Double(rate) / 1_000.0) }
    return "\(rate) Hz"
  }

  private func formattedAudioBitrate(_ bitrate: Double) -> String {
    guard bitrate.isFinite, bitrate > 0 else { return "—" }
    return bitrate >= 1_000 ? String(format: "%.2f Mbps", bitrate / 1_000.0) : String(format: "%.1f kbps", bitrate)
  }

  private func formattedVideoBitrate(_ bitrate: Double) -> String {
    guard bitrate.isFinite, bitrate > 0 else { return "—" }
    return String(format: "%.2f Mbps", bitrate)
  }
}

/// A compact two-channel peak/RMS meter. Values arrive as linear 0…1 levels
/// from the DeckLink callback; the marker is the peak and the filled body is
/// RMS. Keeping the conversion and clamping here avoids making the capture
/// queue do presentation work or sending audio samples through SwiftUI.
struct AudioLevelMeter: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Label("Embedded audio", systemImage: "waveform")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Text(audioSummary)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(model.update.audioPresent ? .secondary : .tertiary)
      }
      AudioLevelRow(label: "L", rms: model.update.audioRMSLeft, peak: model.update.audioPeakLeft)
      AudioLevelRow(label: "R", rms: model.update.audioRMSRight, peak: model.update.audioPeakRight)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Two channel embedded audio meter")
  }

  private var audioSummary: String {
    guard model.update.audioPresent else { return "No signal" }
    let channels = model.update.audioChannels > 0 ? "\(model.update.audioChannels) ch" : "Audio"
    guard model.update.audioSampleRate > 0 else { return channels }
    return "\(channels) · \(formatSampleRate(model.update.audioSampleRate))"
  }

  private func formatSampleRate(_ rate: Int) -> String {
    rate >= 1_000 ? String(format: "%.1f kHz", Double(rate) / 1_000.0) : "\(rate) Hz"
  }
}

private struct AudioLevelRow: View {
  let label: String
  let rms: Double
  let peak: Double

  var body: some View {
    HStack(spacing: 7) {
      Text(label).font(.caption2.weight(.semibold).monospaced()).foregroundStyle(.secondary)
        .frame(width: 12, alignment: .leading)
      LevelBar(rms: rms, peak: peak)
        .frame(height: 9)
      Text(decibelText(peak))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 49, alignment: .trailing)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio channel \(label)")
    .accessibilityValue("Peak \(decibelText(peak)), RMS \(decibelText(rms))")
  }
}

private struct LevelBar: View {
  let rms: Double
  let peak: Double

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let rmsWidth = width * normalized(rms)
      let peakX = width * normalized(peak)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.10))
        Capsule().fill(LinearGradient(
          colors: [.green, .yellow, .orange, .red],
          startPoint: .leading, endPoint: .trailing
        )).frame(width: max(2, rmsWidth))
        Capsule().fill(Color.white.opacity(0.95)).frame(width: 2).offset(x: max(0, peakX - 1))
      }
      .clipShape(Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
    .accessibilityHidden(true)
  }
}

private func normalized(_ value: Double) -> Double {
  guard value.isFinite else { return 0 }
  return min(1, max(0, value))
}

private func decibelText(_ linear: Double) -> String {
  let level = normalized(linear)
  guard level > 0.000001 else { return "−∞ dB" }
  return String(format: "%.1f dB", max(-60, 20 * log10(level)))
}

struct PipelineControls: View {
  @Bindable var model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 7 : 10) {
      if compact {
        HStack {
          Text("Effects · applied in order").font(.caption.weight(.medium)).foregroundStyle(.secondary)
          Spacer()
          if !model.pipelineEnabled { Text("Bypass selected").font(.caption2).foregroundStyle(.orange) }
        }
      }
      if compact { controls } else { HStack(alignment: .top, spacing: 12) { controls } }
    }
    .disabled(model.loading)
  }

  @ViewBuilder private var controls: some View {
    PipelineToggle(title: "1  LUT", detail: model.lutLoaded ? "Loaded .cube" : "Optional · load a .cube", value: $model.configuration.applyLUT, compact: compact)
      .disabled(!model.lutLoaded).help(model.lutLoaded ? model.lutFileName ?? model.lutTitle : "Load a .cube file to enable this effect. Other effects work without a LUT.")
    PipelineToggle(title: "2  Downscale", detail: "1080p · Lanczos 3", value: $model.configuration.downscale, compact: compact)
      .help("High-quality Lanczos downsampling after the LUT.")
    PipelineToggle(title: "3  Color", detail: "4:2:0 · 8-bit", value: $model.configuration.convertTo420, compact: compact)
      .help("On: 4:2:0 8-bit. Off: 4:2:2 10-bit. Conversion happens after the LUT and scaling.")
    PipelineToggle(title: "4  Frame rate", detail: "Limit to 29.97 fps", value: $model.configuration.reduceFrameRate, compact: compact)
      .help("Reduce a 59.94 input to 29.97 after pixel processing. A 29.97 input stays unchanged.")
  }
}

private struct PipelineToggle: View {
  let title: String
  let detail: String
  @Binding var value: Bool
  var compact: Bool

  var body: some View {
    if compact {
      HStack(spacing: 8) {
        Toggle(title, isOn: $value).toggleStyle(.checkbox)
        Spacer(minLength: 4)
        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }.frame(minHeight: 23)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        Toggle(title, isOn: $value).toggleStyle(.checkbox).font(.caption.weight(.medium))
        Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LUTControls: View {
  @Bindable var model: AppModel
  var compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 9) {
        Image(systemName: "cube.transparent").font(.system(size: 18)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.loading ? "Loading LUT…" : model.lutFileName ?? model.lutTitle)
            .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            .help(model.lutFileName ?? model.lutTitle)
          if !compact { Text(model.lutLoaded ? model.lutTitle : "A LUT is optional. Other effects are ready to use.")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        Spacer(minLength: 4)
        if model.loading { ProgressView().controlSize(.small) }
        Button(model.lutLoaded ? "Change…" : "Load LUT…", action: model.chooseLUT)
          .disabled(model.loading).help("Choose a .cube LUT. Your selection is remembered between launches.")
          .accessibilityLabel(model.lutLoaded ? "Change LUT" : "Load LUT")
        if !compact {
          Divider().frame(height: 28).padding(.horizontal, 4)
          VStack(alignment: .leading, spacing: 3) {
            Text("LUT input").font(.caption2).foregroundStyle(.secondary)
            gamutPicker
          }.frame(width: 250)
        }
      }
      if compact {
        DisclosureGroup("LUT input") { gamutPicker.padding(.top, 5) }.font(.caption)
      }
      if let error = model.lutError {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var gamutPicker: some View {
    Picker("LUT input", selection: $model.gamut) {
      Text("S-Gamut3.Cine / S-Log3").tag("S-Gamut3.Cine / S-Log3")
      Text("S-Gamut3 / S-Log3").tag("S-Gamut3 / S-Log3")
    }
    .labelsHidden().font(.caption)
    .help("The input your LUT expects. This label does not add another log transform. The LUT should output Rec.709.")
  }
}

struct FeedNotice: View {
  let model: AppModel

  var body: some View {
    let message = model.update.message
    // Normal operating state is already shown by the feed and effect badges.
    // Keep actionable errors visible rather than burying them in diagnostics.
    if model.lutError != message && ((!model.running && message != "Stopped"
      && !message.hasPrefix("LUT loaded.") && !message.hasPrefix("Select the"))
      || message.hasPrefix("Saved LUT could not") || message.hasPrefix("LUT was not changed")) {
      Label(message, systemImage: "info.circle")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct CameraOutputControls: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("Virtual camera", systemImage: "video").font(.caption.weight(.medium))
        Spacer()
        if model.running && model.update.cameraOutputActive {
          Text("Connected").font(.caption2).foregroundStyle(.green)
        }
      }
      Text(model.installer.canRequestChanges ? model.update.cameraMessage : "A signed build is required for camera output.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("Setup & details") {
        VStack(alignment: .leading, spacing: 9) {
          if let reason = model.installer.unavailableReason {
            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          HStack {
            Button("Install camera", action: model.installer.install)
            Button("Remove camera", action: model.installer.uninstall)
          }
          .disabled(!model.installer.canRequestChanges || model.installer.pending || model.running)
          if model.installer.status != model.installer.unavailableReason {
            Text(model.installer.status).font(.caption2).foregroundStyle(.secondary)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
        }.padding(.top, 7)
      }.font(.caption)
    }
  }
}

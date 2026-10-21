import SwiftUI

/// On-demand inspector for the selected camera's deeper settings (D5).
/// Rebuilds the context inside its own body so this column refreshes with the models.
struct UIInspectorView: View {
  let context: UIContext
  var body: some View { UIInspectorViewContent(context: context.current) }
}

struct UIInspectorViewContent: View {
  let context: UIContext
  @State private var renaming = false
  @State private var nameDraft = ""

  private static let gamuts = ["S-Gamut3.Cine / S-Log3", "S-Gamut3 / S-Log3"]

  var body: some View {
    if let camera = context.presentation.selected, let snapshot = context.snapshot(camera.id) {
      form(camera: camera, snapshot: snapshot)
    } else {
      ContentUnavailableView("No Camera Selected", systemImage: "video.slash",
        description: Text("Select a camera to see its settings."))
    }
  }

  private func form(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Form {
      Section {
        header(camera: camera, snapshot: snapshot)
      }
      sourceSection(camera: camera, snapshot: snapshot)
      processingSection(camera: camera, snapshot: snapshot)
      lutSection(camera: camera, snapshot: snapshot)
      recordingSection(camera: camera, snapshot: snapshot)
      automationSection(camera: camera, snapshot: snapshot)
      Section {
        HStack {
          Button("Rename…") { nameDraft = camera.name; renaming = true }
            .disabled(!context.session.canEditTopology)
            .help(context.session.canEditTopology ? "Rename this camera." : "Stop all cameras and recordings to rename.")
          Spacer()
          // The bridge asks for confirmation before removing.
          Button("Remove Camera…", role: .destructive) { context.send(.removeCamera(cameraID: camera.id)) }
            .disabled(!context.session.canEditTopology || context.presentation.cameras.count < 2)
            .help(!context.session.canEditTopology ? "Stop all cameras and recordings to remove a camera."
              : context.presentation.cameras.count < 2 ? "Ultracam needs at least one camera." : "Remove this camera and its settings.")
        }
      }
    }
    .formStyle(.grouped)
    .alert("Rename \(camera.name)", isPresented: $renaming) {
      TextField("Name", text: $nameDraft)
      Button("Rename") {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { context.send(.renameCamera(cameraID: camera.id, name: trimmed)) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      // The camera extension keeps the device name it published until it restarts.
      Text("Meeting apps list the new name after the camera extension restarts, for example after restarting your Mac.")
    }
  }

  /// The camera's name and state, in place of a "Camera" row.
  private func header(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(camera.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        Text(camera.inputName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 4)
      UIBadge(text: camera.statusBadge, tone: camera.statusTone)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Sections

  private func sourceSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Picker("Input", selection: Binding(
        get: { context.inputs.first { $0.name == snapshot.inputName }?.id ?? "" },
        set: { context.send(.setInput(cameraID: camera.id, deviceID: $0)) })) {
        if snapshot.inputName == nil { Text("No input").tag("") }
        ForEach(context.inputs) { Text($0.name).tag($0.id) }
      }
      .disabled(snapshot.running)
      .help(snapshot.running ? "Stop the camera to change its input." : "Choose the Blackmagic capture device.")
      LabeledContent("Signal") {
        Text(signalText(snapshot)).lineLimit(1)
          .foregroundStyle(camera.statusTone == .warning ? Color.orange : .secondary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Signal")
      .accessibilityValue(signalText(snapshot))
      if snapshot.running {
        LabeledContent("Timecode") { Text(camera.timecode).monospacedDigit().textSelection(.enabled) }
      }
      Toggle("Video Preview", isOn: Binding(get: { snapshot.previewEnabled },
        set: { context.send(.setPreviewEnabled(cameraID: camera.id, $0)) }))
        .help("Hidden previews do no rendering work. Camera output continues.")
    } header: {
      HStack {
        Text("Source")
        Spacer()
        Button { context.send(.refreshInputs) } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .disabled(snapshot.running)
          .help("Refresh capture devices")
          .accessibilityLabel("Refresh capture devices")
      }
    }
  }

  private func processingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle("Processing", isOn: Binding(get: { snapshot.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) }))
        .help("Off is a complete bypass: original resolution, color, pixels and frame rate. Your effect choices stay saved. ⇧⌘B")
      ForEach(camera.chips) { chip in
        Toggle(isOn: Binding(get: { chip.isOn }, set: { context.send(.setEffect(cameraID: camera.id, index: chip.id, $0)) })) {
          HStack(spacing: 6) {
            Text("\(chip.id + 1)").monospacedDigit().foregroundStyle(.tertiary)
            Text(UIPresentationBuilder.effectLongTitles[chip.id]).lineLimit(1)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(!chip.enabled || !snapshot.processing)
        .help(chip.help)
      }
    } header: {
      Text("Processing")
    } footer: {
      Group {
        if camera.applying {
          Label("Updating output…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        } else if !snapshot.processing {
          Text("Complete bypass: the camera original goes out unchanged.").foregroundStyle(.orange)
        } else if let output = snapshot.outputFormat {
          Text("Applied in order. Output \(output).").foregroundStyle(.secondary)
        }
      }
      .font(.caption)
    }
  }

  private func lutSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section("LUT") {
      LabeledContent {
        HStack(spacing: 6) {
          if snapshot.lutLoading { ProgressView().controlSize(.small) }
          Button(snapshot.lutName == nil ? "Load…" : "Change…") { context.send(.chooseLUT(cameraID: camera.id)) }
            .disabled(snapshot.lutLoading)
            .help("Choose a .cube LUT. Your selection is remembered between launches. ⌘O")
        }
      } label: {
        Text(snapshot.lutLoading ? "Loading LUT…" : snapshot.lutName ?? "No LUT loaded")
          .lineLimit(1).truncationMode(.middle)
          .foregroundStyle(snapshot.lutName == nil ? .secondary : .primary)
          .help(snapshot.lutName ?? "")
      }
      if let error = snapshot.lutError {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Picker("Input gamut", selection: Binding(get: { snapshot.gamut }, set: { context.send(.setGamut(cameraID: camera.id, $0)) })) {
        ForEach(Self.gamuts, id: \.self) { Text($0).tag($0) }
      }
      .help("The input your LUT expects. This label does not add another log transform. The LUT should output Rec.709.")
    }
  }

  private func recordingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      LabeledContent {
        Button("Choose…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
          .help("Choose a recording folder for \(camera.name). Applies to the next take.")
      } label: {
        Text(camera.folderLine).lineLimit(1).truncationMode(.middle)
        Text(snapshot.recording.folderIsCustom ? "Own folder" : "Default folder")
      }
      .help(snapshot.recording.folderPath ?? "")
      if snapshot.recording.folderIsCustom {
        Button("Use Default Folder") { context.send(.useDefaultFolder(cameraID: camera.id)) }
      }
      if let left = camera.timeLeftLine { LabeledContent("Time left", value: left) }
    } header: {
      Text("Recording")
    } footer: {
      Text("Records the camera original with embedded audio: no LUT or effects.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func automationSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle("Start with camera apps", isOn: Binding(get: { snapshot.automaticStart },
        set: { context.send(.setAutomaticStart(cameraID: camera.id, $0)) }))
        .help("Starts when a meeting app opens this camera; stops when the last app closes.")
      if snapshot.automaticStartFailed {
        HStack {
          Label("Couldn't start", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Spacer()
          Button("Retry") { context.send(.retryAutomaticStart) }
            .help("Try starting the camera once more. There is no background retry loop.")
        }
      }
    } header: {
      Text("Automation")
    } footer: {
      if let status = snapshot.automaticStatus, !status.isEmpty {
        Text(status).font(.caption).foregroundStyle(snapshot.automaticStartFailed ? .orange : .secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
  }

  private func signalText(_ snapshot: UICameraSnapshot) -> String {
    switch snapshot.signal {
    case .none: return snapshot.deviceAvailable ? "Camera stopped" : "Input missing"
    case .connecting: return "Starting…"
    case .live(let format): return "\(format) · 4:2:2"
    case .noSignal: return "No HDMI signal"
    case .unsupported(let mode): return mode
    case .deviceMissing: return "Input disconnected"
    }
  }
}

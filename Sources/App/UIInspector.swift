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
  @State private var confirmingRemove = false

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
        LabeledContent("Camera") { Text(camera.name).lineLimit(1).truncationMode(.middle) }
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
          Button("Remove Camera…", role: .destructive) { confirmingRemove = true }
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
      Text("Its virtual camera becomes \u{201C}Ultracam · <name>\u{201D}.")
    }
    .confirmationDialog("Remove \(camera.name)?", isPresented: $confirmingRemove) {
      Button("Remove Camera", role: .destructive) { context.send(.removeCamera(cameraID: camera.id)) }
    } message: {
      Text("Its settings and virtual camera are removed. Recordings stay on disk.")
    }
  }

  // MARK: Sections

  private func sourceSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section("Source") {
      HStack {
        Picker("Input", selection: Binding(
          get: { context.inputs.first { $0.name == snapshot.inputName }?.id ?? "" },
          set: { context.send(.setInput(cameraID: camera.id, deviceID: $0)) })) {
          if snapshot.inputName == nil { Text("No input").tag("") }
          ForEach(context.inputs) { Text($0.name).tag($0.id) }
        }
        .disabled(snapshot.running)
        .help(snapshot.running ? "Stop the camera to change its input." : "Choose the Blackmagic capture device.")
        Button { context.send(.refreshInputs) } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .disabled(snapshot.running)
          .help("Refresh capture devices")
          .accessibilityLabel("Refresh capture devices")
      }
      LabeledContent("Signal") {
        Text(signalText(snapshot)).foregroundStyle(camera.statusTone == .warning ? Color.orange : .secondary)
      }
      LabeledContent("Timecode") { Text(camera.timecode).font(.body.monospacedDigit()).textSelection(.enabled) }
      Toggle("Video Preview", isOn: Binding(get: { snapshot.previewEnabled },
        set: { context.send(.setPreviewEnabled(cameraID: camera.id, $0)) }))
        .help("Hidden previews do no rendering work. Camera output continues.")
    }
  }

  private func processingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle(isOn: Binding(get: { snapshot.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) })) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Processing")
          Text("Off = complete bypass: original resolution, color, pixels and frame rate.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .help("Turn off for complete bypass. Your effect selections stay saved. ⇧⌘B")
      ForEach(camera.chips) { chip in
        Toggle(isOn: Binding(get: { chip.isOn }, set: { context.send(.setEffect(cameraID: camera.id, index: chip.id, $0)) })) {
          VStack(alignment: .leading, spacing: 1) {
            Text("\(chip.id + 1) · \(UIPresentationBuilder.effectLongTitles[chip.id])")
            Text(chip.id == 0 ? (snapshot.lutName == nil ? "Load a .cube to enable" : "Doesn't change the camera output format")
              : "Changes the camera output format")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(!chip.enabled || !snapshot.processing)
        .help(chip.help)
      }
    } header: {
      Text("Processing · applied in order")
    } footer: {
      if camera.applying {
        Label("Updating output…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
      } else if !snapshot.processing {
        Text("Complete bypass").font(.caption).foregroundStyle(.orange)
      } else if let output = snapshot.outputFormat {
        Label("Effects active · \(output)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
      }
    }
  }

  private func lutSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section("LUT") {
      HStack {
        Image(systemName: "cube").foregroundStyle(.secondary)
        Text(snapshot.lutLoading ? "Loading LUT…" : snapshot.lutName ?? "No LUT loaded")
          .lineLimit(1).truncationMode(.middle)
          .foregroundStyle(snapshot.lutName == nil ? .secondary : .primary)
        Spacer(minLength: 4)
        if snapshot.lutLoading { ProgressView().controlSize(.small) }
        Button(snapshot.lutName == nil ? "Load LUT…" : "Change…") { context.send(.chooseLUT(cameraID: camera.id)) }
          .disabled(snapshot.lutLoading)
          .help("Choose a .cube LUT. Your selection is remembered between launches.")
      }
      if let error = snapshot.lutError {
        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Picker("LUT input", selection: Binding(get: { snapshot.gamut }, set: { context.send(.setGamut(cameraID: camera.id, $0)) })) {
        ForEach(Self.gamuts, id: \.self) { Text($0).tag($0) }
      }
      .help("The input your LUT expects. This label does not add another log transform. The LUT should output Rec.709.")
    }
  }

  private func recordingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      HStack {
        Image(systemName: "folder").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(camera.folderLine).lineLimit(1).truncationMode(.middle).help(snapshot.recording.folderPath ?? "")
          Text(snapshot.recording.folderIsCustom ? "Own folder · applies to the next take" : "Default folder · applies to the next take")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        if snapshot.recording.folderIsCustom {
          Button("Use Default") { context.send(.useDefaultFolder(cameraID: camera.id)) }.buttonStyle(.borderless)
        }
        Button("Choose…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
          .help("Choose a recording folder for \(camera.name).")
      }
      if let left = camera.timeLeftLine { LabeledContent("Time left", value: left) }
    } header: {
      Text("Recording")
    } footer: {
      Text("Records the camera original: 2160p 10-bit 4:2:2 with embedded audio. No LUT or effects.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func automationSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section("Automation") {
      Toggle(isOn: Binding(get: { snapshot.automaticStart }, set: { context.send(.setAutomaticStart(cameraID: camera.id, $0)) })) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Start with camera apps")
          Text("Starts when a meeting app opens this camera; stops when the last app closes.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let status = snapshot.automaticStatus {
        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if status.localizedCaseInsensitiveContains("retry") {
          Button("Retry") { context.send(.retryAutomaticStart) }.controlSize(.small)
        }
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

import MonitorToolsCore
import MonitorToolsUI
import SwiftUI

/// One camera: its picture with overlays, then its channel strip.
struct UICameraColumnView: View {
  let camera: UICameraPresentation
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      UICameraPictureView(camera: camera, context: context)
      UIChannelStripView(camera: camera, context: context)
    }
  }
}

// MARK: - Picture

/// The picture at 16:9 with its overlays. At rest it shows only the camera's
/// identity, tally, recording state and active tools; the tool bar and view
/// controls appear on hover or keyboard focus. A click selects the camera and
/// never cuts (cuts come only from explicit cut controls).
struct UICameraPictureView: View {
  let camera: UICameraPresentation
  let context: UIContext
  var compact = false
  @State private var hovering = false
  @State private var zoom = 1.0
  @FocusState private var focused: Bool

  private var revealed: Bool { (hovering || focused) && !compact }
  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  private var isProgramMode: Bool { context.presentation.outputMode == .program }

  var body: some View {
    ZStack {
      context.pictures.picture(cameraID: camera.id, compact: compact)
        .modifier(MonitorPictureZoom(zoom))
        .accessibilityElement()
        .accessibilityLabel(camera.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { context.send(.select(cameraID: camera.id)) }
        .accessibilityAction(named: "Select \(camera.name)") { context.send(.select(cameraID: camera.id)) }
        .modifier(UICutAccessibilityAction(camera: camera, context: context))
      placeholder
      overlays
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
    .overlay {
      if let color = camera.tally.ringColor {
        RoundedRectangle(cornerRadius: compact ? 10 : 14).strokeBorder(color, lineWidth: camera.tally == .onAir ? 4 : 3)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      if camera.selected && !compact {
        RoundedRectangle(cornerRadius: 17).strokeBorder(Color.accentColor, lineWidth: 2.5)
          .padding(-4).allowsHitTesting(false)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { context.send(.select(cameraID: camera.id)) }
    .onHover { hovering = $0 }
    .focusable(!compact)
    .focused($focused)
    .onChange(of: focused) { _, isFocused in
      if isFocused && !camera.selected { context.send(.select(cameraID: camera.id)) }
    }
    .contextMenu { pictureMenu }
  }

  // MARK: Placeholders

  @ViewBuilder private var placeholder: some View {
    switch camera.tileState {
    case .live:
      EmptyView()
    case .connecting:
      UIPicturePlaceholder(symbol: "video", title: "Starting…", detail: "Waiting for the first frame from \(camera.inputName).",
        showsProgress: true)
    case .noSignal:
      UIPicturePlaceholder(symbol: "video.slash", title: "No HDMI signal",
        detail: "Check the camera's HDMI output: 2160p 29.97 or 59.94, 10-bit 4:2:2, RAW off, display LUT off.")
    case .unsupported(let mode):
      UIPicturePlaceholder(symbol: "exclamationmark.triangle", title: "Unsupported format",
        detail: mode.isEmpty ? "Waiting for 2160p 29.97 or 59.94, 10-bit 4:2:2." : "\(mode) Waiting for 2160p 29.97 or 59.94.")
    case .deviceMissing:
      UIPicturePlaceholder(symbol: "cable.connector.slash", title: "Input disconnected",
        detail: "Reconnect \(camera.inputName) or choose another input.") {
        Button("Refresh Inputs") { context.send(.refreshInputs) }
      }
    case .stopped:
      UIPicturePlaceholder(symbol: "video", title: "Camera stopped", detail: "Start the camera to see its HDMI input.") {
        Button("Start Camera", systemImage: "play.fill") { context.send(.startCamera(cameraID: camera.id)) }
          .disabled(!camera.canStart)
      }
    case .previewHidden:
      UIPicturePlaceholder(symbol: "eye.slash", title: "Preview hidden",
        detail: "Camera output continues. Hidden previews do no rendering work.") {
        Button("Show Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, true)) }
      }
    case .updating:
      Label("Updating output…", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption.weight(.medium))
        .uiPictureOverlay()
        .accessibilityLabel("Updating output")
    }
  }

  // MARK: Overlays

  private var overlays: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 6) {
        if isProgramMode {
          Text("\(camera.number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .frame(width: 20, height: 20)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
            .accessibilityHidden(true)
        }
        Text(camera.name)
          .font(.caption.weight(.semibold))
          .lineLimit(1).truncationMode(.tail)
          .uiPictureOverlay()
          .help(camera.name)
        UITallyBadge(tally: camera.tally)
        Spacer(minLength: 4)
        if revealed {
          UIMonitorToolButtons(camera: camera, context: context)
        } else if !camera.activeTools.isEmpty && !compact {
          HStack(spacing: 3) {
            ForEach(camera.activeTools, id: \.self) { tool in
              Image(systemName: tool.symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.72), in: Capsule())
                .foregroundStyle(.white)
                .help("\(tool.title) is on")
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Active tools: " + camera.activeTools.map(\.title).joined(separator: ", "))
        }
      }
      Spacer(minLength: 0)
      HStack(alignment: .bottom, spacing: 6) {
        if revealed {
          Text(camera.timecode).font(.caption.monospacedDigit().weight(.medium)).uiPictureOverlay()
            .accessibilityLabel("Timecode \(camera.timecode)")
          signalMenu
        }
        Spacer(minLength: 4)
        if revealed { viewControls }
        Spacer(minLength: 4)
        recordingPill
      }
    }
    .padding(compact ? 6 : 10)
    .animation(.easeOut(duration: 0.15), value: revealed)
  }

  @ViewBuilder private var recordingPill: some View {
    let elapsed = UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0)
    switch camera.stripState {
    case .recording, .updating:
      HStack(spacing: 5) {
        Circle().fill(.red).frame(width: 8, height: 8)
        Text("REC \(elapsed)").font(.caption.weight(.semibold).monospacedDigit())
      }
      .uiPictureOverlay()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording \(elapsed)")
    case .paused:
      HStack(spacing: 5) {
        Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.orange)
        Text("Paused \(elapsed)").font(.caption.weight(.semibold).monospacedDigit())
      }
      .uiPictureOverlay()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording paused at \(elapsed)")
    case .recordingNoSignal:
      HStack(spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
        Text("REC · no signal").font(.caption.weight(.semibold))
      }
      .foregroundStyle(.orange)
      .padding(.horizontal, 8).frame(height: 24)
      .background(Color.black.opacity(0.72), in: Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recording, no signal")
    default:
      EmptyView()
    }
  }

  private var signalMenu: some View {
    let stage = context.monitor.configuration(for: camera.id).pictureStage
    return Menu {
      Picker("Picture", selection: Binding(
        get: { context.monitor.configuration(for: camera.id).pictureStage },
        set: { value in
          var next = context.monitor.configuration(for: camera.id)
          next.pictureStage = value
          context.monitor.setConfiguration(next, for: camera.id)
        })) {
        Text("Output (as published)").tag(MonitorStage.processedOutput)
        Text("Source (camera signal)").tag(MonitorStage.source)
      }
      .pickerStyle(.inline)
    } label: {
      Text(stage == .source ? "Source" : "Output").font(.caption.weight(.medium))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .fixedSize()
    .uiPictureOverlay()
    .help("Choose what this picture shows")
    .accessibilityLabel("Picture signal")
    .accessibilityValue(stage == .source ? "Source" : "Output")
  }

  private var viewControls: some View {
    HStack(spacing: 2) {
      overlayButton("snowflake", help: "Freeze (⌃⌥F)", label: "Freeze") { context.send(.freeze(cameraID: camera.id)) }
      overlayButton("rectangle.dashed", help: "Clean View (⌃⌥C)", label: "Clean View") { context.send(.toggleClean(cameraID: camera.id)) }
      Menu {
        Picker("Zoom", selection: $zoom) {
          Text("Fit").tag(1.0)
          Text("150%").tag(1.5)
          Text("200%").tag(2.0)
          Text("400%").tag(4.0)
        }
        .pickerStyle(.inline)
      } label: {
        Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))%").font(.caption.weight(.medium))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Zoom (center crop, this view only)")
      .accessibilityLabel("Zoom")
      overlayButton("arrow.up.forward.square", help: "Detach to Window", label: "Detach to Window") {
        context.send(.detachMonitor(cameraID: camera.id))
      }
    }
    .padding(.horizontal, 4).frame(height: 30)
    .background(Color.black.opacity(0.72), in: Capsule())
    .environment(\.colorScheme, .dark)
  }

  private func overlayButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 24).foregroundStyle(.white).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(label)
  }

  @ViewBuilder private var pictureMenu: some View {
    Button("Freeze") { context.send(.freeze(cameraID: camera.id)) }
    Button("Clean View") { context.send(.toggleClean(cameraID: camera.id)) }
    Button("Reset Monitor Tools") { context.send(.resetMonitorTools(cameraID: camera.id)) }
    let others = context.presentation.cameras.filter { $0.id != camera.id }
    if !others.isEmpty {
      Menu("Copy Settings To") {
        ForEach(others) { other in
          Button(other.name) { context.send(.copyMonitorSettings(from: camera.id, to: other.id)) }
        }
      }
    }
    Divider()
    Button("Detach to Window") { context.send(.detachMonitor(cameraID: camera.id)) }
    Button("Hide Preview") { context.send(.setPreviewEnabled(cameraID: camera.id, false)) }
    Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
  }
}

/// Adds the named "Cut to Camera N" accessibility action only when a cut is possible.
private struct UICutAccessibilityAction: ViewModifier {
  let camera: UICameraPresentation
  let context: UIContext
  func body(content: Content) -> some View {
    if camera.showsCut && camera.cutEnabled {
      content.accessibilityAction(named: "Cut to \(camera.name)") { context.send(.cut(cameraID: camera.id)) }
    } else {
      content
    }
  }
}

private struct UIPicturePlaceholder<Actions: View>: View {
  let symbol: String
  let title: String
  let detail: String
  var showsProgress = false
  @ViewBuilder var actions: () -> Actions

  init(symbol: String, title: String, detail: String, showsProgress: Bool = false,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
    self.symbol = symbol
    self.title = title
    self.detail = detail
    self.showsProgress = showsProgress
    self.actions = actions
  }

  var body: some View {
    ZStack {
      Color(white: 0.06)
      VStack(spacing: 6) {
        if showsProgress { ProgressView().controlSize(.small) }
        else { Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.6)) }
        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
          .multilineTextAlignment(.center).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
        actions().controlSize(.small).padding(.top, 2)
      }
      .padding(.horizontal, 24)
    }
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

// MARK: - Channel strip

/// A camera's own controls under its picture: recording, output, effects and audio.
struct UIChannelStripView: View {
  let camera: UICameraPresentation
  let context: UIContext
  @State private var renaming = false
  @State private var nameDraft = ""

  private var snapshot: UICameraSnapshot? { context.snapshot(camera.id) }
  private var isRecordingOrPaused: Bool { camera.pauseTitle != nil }

  var body: some View {
    Group {
      if camera.collapsed { collapsed } else { expanded }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, camera.collapsed ? 6 : 10)
    .background(background, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: camera.selected ? 1.5 : 1))
    .alert("Rename \(camera.name)", isPresented: $renaming) {
      TextField("Camera name", text: $nameDraft)
      Button("Rename") {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { context.send(.renameCamera(cameraID: camera.id, name: trimmed)) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(camera.name) controls")
  }

  private var stateTone: UITone? {
    switch camera.stripState {
    case .recordingNoSignal, .noFolder: return .warning
    case .failed: return .critical
    default: return nil
    }
  }

  private var background: Color {
    if let tone = stateTone { return tone.color.opacity(0.08) }
    return Color.primary.opacity(0.045)
  }

  private var borderColor: Color {
    if let tone = stateTone { return tone.color.opacity(0.5) }
    return camera.selected ? Color.accentColor.opacity(0.55) : .clear
  }

  // MARK: Expanded

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Divider()
      recordRow
      folderRow
      Divider()
      outputRow
      HStack(spacing: 8) {
        Text("AUDIO").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 42, alignment: .leading)
        UIAudioMeter(audio: camera.audio)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      chevron
      Text(camera.name).font(.headline).lineLimit(1).truncationMode(.middle)
        .help("\(camera.name) · \(camera.inputName)")
      UIBadge(text: camera.statusBadge, tone: camera.statusTone)
      tallyBadge
      Spacer(minLength: 4)
      ViewThatFits(in: .horizontal) {
        cameraButton(compact: false)
        cameraButton(compact: true)
      }
      overflowMenu
    }
  }

  private var chevron: some View {
    Button { context.send(.toggleCollapsed(cameraID: camera.id)) } label: {
      Image(systemName: camera.collapsed ? "chevron.right" : "chevron.down")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(camera.collapsed ? "Expand" : "Collapse")
    .accessibilityLabel(camera.collapsed ? "Expand \(camera.name)" : "Collapse \(camera.name)")
  }

  @ViewBuilder private var tallyBadge: some View {
    switch camera.tally {
    case .onAir: UIBadge(text: "On air", tone: .critical)
    case .program: UIBadge(text: "Program", tone: .neutral)
    case .next: UIBadge(text: "Next", tone: .positive)
    case .none: EmptyView()
    }
  }

  @ViewBuilder private func cameraButton(compact: Bool) -> some View {
    if camera.canStop {
      Button { context.send(.stopCamera(cameraID: camera.id)) } label: {
        if compact { Image(systemName: "stop.fill") } else { Label("Stop Camera", systemImage: "stop.fill") }
      }
      .controlSize(.small)
      .help(camera.stopNeedsConfirmation ? "Stops capture and output. Asks first because it would end a recording or on-air video."
        : "Stops this camera's capture and output.")
      .accessibilityLabel("Stop \(camera.name)")
    } else {
      Button { context.send(.startCamera(cameraID: camera.id)) } label: {
        if compact { Image(systemName: "play.fill") } else { Label("Start Camera", systemImage: "play.fill") }
      }
      .controlSize(.small)
      .disabled(!camera.canStart)
      .help(camera.canStart ? "Start capture from \(camera.inputName)." : "Connect the camera's input first.")
      .accessibilityLabel("Start \(camera.name)")
    }
  }

  private var overflowMenu: some View {
    Menu {
      Button("Show Inspector") { context.send(.showInspector(cameraID: camera.id)) }
      if context.presentation.outputMode == .program {
        Button("Cut to \(camera.name) (⌃\(camera.number))") { context.send(.cut(cameraID: camera.id)) }
          .disabled(!camera.cutEnabled)
      }
      Divider()
      Button(camera.recordButtonActive || camera.pauseTitle == "Resume" ? "Stop Recording" : "Record") {
        context.send(.toggleRecording(cameraID: camera.id))
      }
      .disabled(!camera.recordButtonEnabled)
      if let pause = camera.pauseTitle {
        Button(pause == "Pause" ? "Pause Recording" : "Resume Recording") { context.send(.pauseOrResume(cameraID: camera.id)) }
      }
      Divider()
      Button("Load LUT…") { context.send(.chooseLUT(cameraID: camera.id)) }
      Button("Choose Recording Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
      if snapshot?.recording.folderIsCustom == true {
        Button("Use Default Folder") { context.send(.useDefaultFolder(cameraID: camera.id)) }
      }
      let others = context.presentation.cameras.filter { $0.id != camera.id }
      if !others.isEmpty {
        Menu("Copy Monitor Settings To") {
          ForEach(others) { other in
            Button(other.name) { context.send(.copyMonitorSettings(from: camera.id, to: other.id)) }
          }
        }
      }
      Divider()
      Button(context.session.canEditTopology ? "Rename…" : "Rename… (stop all cameras first)") {
        nameDraft = camera.name
        renaming = true
      }
      .disabled(!context.session.canEditTopology)
      Button("Diagnostics…") { context.send(.openDiagnostics) }
      Divider()
      if camera.canStop {
        Button("Stop Camera") { context.send(.stopCamera(cameraID: camera.id)) }
      } else {
        Button("Start Camera") { context.send(.startCamera(cameraID: camera.id)) }.disabled(!camera.canStart)
      }
      Button(context.session.canEditTopology ? "Remove Camera…" : "Remove Camera… (stop all cameras first)") {
        context.send(.removeCamera(cameraID: camera.id))
      }
      .disabled(!context.session.canEditTopology || context.presentation.cameras.count < 2)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More for \(camera.name)")
    .accessibilityLabel("More for \(camera.name)")
  }

  private var recordButton: some View {
    UIRecordButton(active: camera.recordButtonActive || camera.pauseTitle == "Resume", enabled: camera.recordButtonEnabled,
      help: camera.recordButtonHelp) {
      context.send(.toggleRecording(cameraID: camera.id))
    }
  }

  private var recordRow: some View {
    HStack(spacing: 10) {
      if camera.stripState == .finishing {
        ProgressView().controlSize(.small).frame(width: 28, height: 28)
      } else {
        recordButton
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(camera.recordTitle.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(camera.recordTone == .neutral ? Color.secondary : camera.recordTone.color)
        if isRecordingOrPaused {
          Text(camera.recordDetail).font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(camera.stripState == .paused ? .secondary : .primary)
        } else {
          Text(camera.recordDetail).font(.caption).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(camera.stripState == .saved ? .primary : .secondary)
        }
      }
      .layoutPriority(1)
      if let size = camera.sizeLine {
        VStack(alignment: .leading, spacing: 2) {
          Text(size).font(.caption.monospacedDigit())
          if let drops = camera.dropsLine {
            Text(drops).font(.caption2.monospacedDigit()).foregroundStyle(camera.dropsWarning ? .orange : .green)
          }
        }
      }
      Spacer(minLength: 4)
      recordActions
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var recordActions: some View {
    switch camera.stripState {
    case .recording, .recordingNoSignal, .updating, .paused:
      if let pause = camera.pauseTitle {
        Button(pause, systemImage: pause == "Pause" ? "pause.fill" : "play.fill") {
          context.send(.pauseOrResume(cameraID: camera.id))
        }
        .controlSize(.small)
      }
    case .saved:
      if let url = snapshot?.recording.savedURL {
        Button("Show in Finder", systemImage: "folder") { context.send(.revealInFinder(url)) }.controlSize(.small)
      }
    case .noFolder:
      Button("Choose Folder…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }.controlSize(.small)
    case .failed:
      HStack(spacing: 6) {
        Button("Show in Finder", systemImage: "folder") {
          if let url = snapshot?.recording.savedURL { context.send(.revealInFinder(url)) } else { context.send(.revealRecordings) }
        }
        Button("Details") { context.send(.openDiagnostics) }
      }
      .controlSize(.small)
    case .stopped:
      Button("Start Camera", systemImage: "play.fill") { context.send(.startCamera(cameraID: camera.id)) }
        .controlSize(.small).disabled(!camera.canStart)
    case .finishing:
      Text("Saving…").font(.caption).foregroundStyle(.secondary)
    case .ready, .waiting:
      EmptyView()
    }
  }

  private var folderRow: some View {
    ViewThatFits(in: .horizontal) {
      folderContent(footnote: true)
      folderContent(footnote: false)
    }
  }

  private func folderContent(footnote: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
      Text(camera.folderLine).font(.caption).lineLimit(1).truncationMode(.middle)
        .help(snapshot?.recording.folderPath ?? camera.folderLine)
      if let left = camera.timeLeftLine {
        Text("· \(left)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
      }
      if snapshot?.recording.folderIsCustom == true {
        UIBadge(text: "Own folder").fixedSize()
      }
      Spacer(minLength: 4)
      if footnote {
        Text("Camera original · no LUT or effects").font(.caption2).foregroundStyle(.tertiary).fixedSize()
      }
    }
  }

  private var outputRow: some View {
    ViewThatFits(in: .horizontal) {
      outputContent(full: true)
      outputContent(full: false)
    }
  }

  private func outputContent(full: Bool) -> some View {
    HStack(spacing: 8) {
      outputLabel(full: full)
      Spacer(minLength: 4)
      if camera.applying {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          if full { Text("Updating output…").font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize()
        .accessibilityLabel("Updating output")
      }
      HStack(spacing: 4) {
        ForEach(camera.chips) { chip in
          UIChipToggle(chip: chip, compact: !full) {
            context.send(.setEffect(cameraID: camera.id, index: chip.id, !chip.isOn))
          }
        }
      }
      .opacity(camera.processing ? 1 : 0.5)
      .fixedSize()
      Toggle(isOn: Binding(get: { camera.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) })) {
        Text("Processing").font(.caption).foregroundStyle(.secondary)
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .fixedSize()
      .help("Off = complete bypass: the original resolution, color, pixels and frame rate. Effect choices stay saved. ⇧⌘B")
    }
  }

  @ViewBuilder private func outputLabel(full: Bool) -> some View {
    if camera.showsCut {
      Button {
        context.send(.cut(cameraID: camera.id))
      } label: {
        Label(full ? "Cut  ⌃\(camera.number)" : "Cut", systemImage: "arrow.left.arrow.right")
      }
      .controlSize(.small)
      .disabled(!camera.cutEnabled)
      .help(camera.cutEnabled ? "Cut Program to \(camera.name) (⌃\(camera.number))" : "\(camera.name) needs a live signal before it can go on air.")
      .accessibilityLabel("Cut to \(camera.name)")
    } else {
      HStack(spacing: 5) {
        Image(systemName: context.presentation.outputMode == .program ? "dot.radiowaves.left.and.right" : "video.badge.checkmark")
          .font(.caption)
        Text(full ? camera.outputLine : (camera.outputInUse ? "In use" : "Not in use"))
          .font(.caption).lineLimit(1).truncationMode(.middle)
      }
      .foregroundStyle(camera.outputInUse ? .green : .secondary)
      .help(camera.outputLine)
      .accessibilityElement(children: .combine)
    }
  }

  // MARK: Collapsed

  private var collapsed: some View {
    HStack(spacing: 7) {
      chevron
      Text(camera.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
      tallyBadge
      collapsedState
      Spacer(minLength: 4)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          HStack(spacing: 3) {
            ForEach(camera.chips) { chip in
              UIChipToggle(chip: chip, compact: true) {
                context.send(.setEffect(cameraID: camera.id, index: chip.id, !chip.isOn))
              }
            }
          }
          .opacity(camera.processing ? 1 : 0.5)
          UIAudioMeter(audio: camera.audio, compact: true)
        }
        UIAudioMeter(audio: camera.audio, compact: true)
        EmptyView()
      }
      if camera.stripState == .finishing {
        ProgressView().controlSize(.mini).frame(width: 22, height: 22)
      } else {
        UIRecordButton(active: camera.recordButtonActive || camera.pauseTitle == "Resume", enabled: camera.recordButtonEnabled,
          help: camera.recordButtonHelp, size: 22) {
          context.send(.toggleRecording(cameraID: camera.id))
        }
      }
      overflowMenu
    }
  }

  @ViewBuilder private var collapsedState: some View {
    let elapsed = UIFormat.shortElapsed(snapshot?.recording.elapsed ?? 0)
    switch camera.stripState {
    case .recording, .updating:
      HStack(spacing: 4) {
        Circle().fill(.red).frame(width: 7, height: 7)
        Text(elapsed).font(.caption.monospacedDigit())
      }
      .accessibilityElement(children: .ignore).accessibilityLabel("Recording \(elapsed)")
    case .recordingNoSignal:
      Label("\(elapsed) · no signal", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        .lineLimit(1)
    case .paused:
      Label(elapsed, systemImage: "pause.fill").font(.caption.monospacedDigit()).foregroundStyle(.orange)
        .accessibilityLabel("Paused at \(elapsed)")
    case .saved: Text("Saved").font(.caption).foregroundStyle(.green)
    case .finishing: Text("Finishing…").font(.caption).foregroundStyle(.secondary)
    case .stopped: Text("Stopped").font(.caption).foregroundStyle(.secondary)
    case .waiting: Text(camera.statusBadge).font(.caption).foregroundStyle(.orange).lineLimit(1)
    case .noFolder: Text("No folder").font(.caption).foregroundStyle(.orange)
    case .failed: Text("Recording stopped").font(.caption).foregroundStyle(.red).lineLimit(1)
    case .ready: Text("Ready").font(.caption).foregroundStyle(.secondary)
    }
  }
}

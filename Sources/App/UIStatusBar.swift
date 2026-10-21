import SwiftUI

/// Bottom status bar. Fixed order: output, Program, recording, audio, warning,
/// then resources on the right. Each segment opens a popover with details.
struct UIStatusBarView: View {
  let context: UIContext
  @State private var open: UIStatusSegment.Kind?
  @State private var resourcesOpen = false

  var body: some View {
    HStack(spacing: 2) {
      ViewThatFits(in: .horizontal) {
        segmentsRow(compact: false)
        segmentsRow(compact: true)
        segmentsRow(compact: true, essentialOnly: true)
      }
      Spacer(minLength: 8)
      UIResourceReadout(open: $resourcesOpen, context: context)
    }
    .padding(.horizontal, 8)
    .frame(height: 30)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Status")
  }

  private func segmentsRow(compact: Bool, essentialOnly: Bool = false) -> some View {
    HStack(spacing: 2) {
      ForEach(Array(visibleSegments(essentialOnly: essentialOnly).enumerated()), id: \.element.id) { index, segment in
        if index > 0 { Divider().frame(height: 14) }
        segmentButton(segment, compact: compact)
      }
    }
    .fixedSize()
  }

  private func visibleSegments(essentialOnly: Bool) -> [UIStatusSegment] {
    let segments = context.presentation.statusSegments
    guard essentialOnly else { return segments }
    return segments.filter { $0.kind == .output || $0.kind == .recording || $0.kind == .warning }
  }

  private func segmentButton(_ segment: UIStatusSegment, compact: Bool) -> some View {
    Button { open = segment.kind } label: {
      HStack(spacing: 5) {
        if segment.kind == .recording && segment.tone == .critical {
          Circle().fill(.red).frame(width: 7, height: 7)
        } else {
          Image(systemName: symbol(segment.kind)).imageScale(.small)
        }
        Text(compact ? shortText(segment) : segment.text).lineLimit(1)
      }
      .font(.caption)
      .foregroundStyle(color(segment))
      .padding(.horizontal, 7).frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(segment.text)
    .accessibilityLabel(segment.text)
    .accessibilityHint("Shows details")
    .popover(isPresented: Binding(get: { open == segment.kind }, set: { if !$0 { open = nil } }), arrowEdge: .top) {
      UIStatusPopover(kind: segment.kind, segment: segment, context: context)
    }
  }

  private func symbol(_ kind: UIStatusSegment.Kind) -> String {
    switch kind {
    case .output: return "video.badge.checkmark"
    case .program: return "tv"
    case .recording: return "record.circle"
    case .audio: return "waveform"
    case .warning: return "exclamationmark.triangle.fill"
    }
  }

  private func color(_ segment: UIStatusSegment) -> Color {
    switch segment.tone {
    case .positive: return .green
    case .warning: return .orange
    case .critical where segment.kind == .recording: return .primary
    case .critical, .onAir: return .red
    case .neutral: return .secondary
    }
  }

  /// Shorter text for narrow windows; the full text stays in the tooltip and popover.
  private func shortText(_ segment: UIStatusSegment) -> String {
    switch segment.kind {
    case .output: return context.presentation.outputInUse ? "In use" : "Not in use"
    case .program: return segment.text.components(separatedBy: " · ").first ?? segment.text
    case .recording: return segment.text.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
    case .audio, .warning: return segment.text
    }
  }
}

// MARK: - Resources

/// App CPU, combined GPU video busy time and memory. Samples once per second only while visible.
struct UIResourceReadout: View {
  @Binding var open: Bool
  let context: UIContext
  @State private var usage = AppResourceUsage()

  var body: some View {
    Button { open = true } label: {
      ViewThatFits(in: .horizontal) {
        Text(fullText)
        Text(shortText)
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 7).frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Total Ultracam process CPU across all threads (100% is one core). GPU (video) is the combined busy time of Ultracam's Metal video processing and copy queues; it excludes the hardware media encoder and the system display compositor.")
    .accessibilityLabel("Ultracam resources")
    .accessibilityValue(fullText)
    .popover(isPresented: $open, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Ultracam total").font(.headline)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow { Text("CPU"); Text(cpu).monospacedDigit() }
          GridRow { Text("GPU (video)"); Text(String(format: "%.1f%%", usage.gpuPercent)).monospacedDigit() }
          GridRow { Text("Memory"); Text(memory).monospacedDigit() }
        }
        Text("CPU counts all Ultracam threads; 100% is one core, so it can exceed 100%. System encoder services run outside this process.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("GPU (video) unions completed Metal processing and copy intervals, so overlapping work counts once. It excludes the hardware media encoder and the display compositor, and is not a whole-machine reading.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Open Diagnostics") { open = false; context.send(.openDiagnostics) }
        }
      }
      .padding(14)
      .frame(width: 320)
    }
    .task {
      var sampler = AppResourceSampler()
      while !Task.isCancelled {
        usage = sampler.sample()
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
    }
  }

  private var cpu: String { usage.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—" }
  private var memory: String {
    usage.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—"
  }
  private var fullText: String { "CPU \(cpu) · GPU (video) \(String(format: "%.1f%%", usage.gpuPercent)) · Memory \(memory)" }
  private var shortText: String { "CPU \(cpu) · GPU \(String(format: "%.0f%%", usage.gpuPercent))" }
}

// MARK: - Popovers

struct UIStatusPopover: View {
  let kind: UIStatusSegment.Kind
  let segment: UIStatusSegment
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch kind {
      case .output: output
      case .program: program
      case .recording: recording
      case .audio: audio
      case .warning:
        Label(segment.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
  }

  private var output: some View {
    Group {
      Text("Output").font(.headline)
      switch context.session.outputMode {
      case .program:
        row(title: "Ultracam · Program", detail: context.session.programInUse ? "In use" : "Not in use",
          positive: context.session.programInUse,
          format: context.session.cameras.first { $0.id == context.session.onAirID }?.outputFormat)
      case .separate:
        ForEach(context.session.cameras) { camera in
          row(title: "Ultracam · \(camera.name)", detail: camera.inUse ? "In use" : "Not in use", positive: camera.inUse,
            format: camera.outputFormat)
        }
      }
      Text("Video only — select your microphone in your meeting app.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func row(title: String, detail: String, positive: Bool, format: String?) -> some View {
    HStack {
      Image(systemName: "video.badge.checkmark").foregroundStyle(positive ? Color.green : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1).truncationMode(.middle)
        Text([detail, format].compactMap { $0 }.joined(separator: " · ")).font(.caption)
          .foregroundStyle(positive ? Color.green : .secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var program: some View {
    Group {
      Text("Program").font(.headline)
      Text(segment.text)
      if context.session.programFormatMismatch {
        Label("Program cameras use different formats. Each cut updates the output briefly.",
          systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !context.session.recentCuts.isEmpty {
        Divider()
        Text("Recent cuts").font(.subheadline.weight(.semibold))
        ForEach(context.session.recentCuts.prefix(5)) { cut in
          HStack {
            Text(cut.at.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(cut.cameraName)
            Spacer()
            UIBadge(text: cut.automatic ? "Auto" : "Manual")
          }
        }
      }
    }
  }

  private var recording: some View {
    Group {
      Text("Recording").font(.headline)
      let takes = context.presentation.cameras.filter { $0.sizeLine != nil }
      if takes.isEmpty {
        Text("Not recording").foregroundStyle(.secondary)
      }
      ForEach(takes) { camera in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Circle().fill(camera.recordTone == .critical ? Color.red : camera.recordTone.color).frame(width: 7, height: 7)
            Text(camera.name).fontWeight(.medium)
            Text("\(camera.recordTitle) · \(camera.recordDetail)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          }
          Text([camera.sizeLine, camera.dropsLine, camera.timeLeftLine].compactMap { $0 }.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(camera.dropsWarning ? Color.orange : .secondary)
        }
        .accessibilityElement(children: .combine)
      }
      ForEach(context.session.drives) { UIDriveRow(drive: $0) }
      HStack {
        Button("Show in Finder") { context.send(.revealRecordings) }
        Spacer()
        if !takes.isEmpty {
          Button("Stop All Recordings") { context.send(.stopAllRecordings) }
            .help("Stop every recording (⌥⌘R)")
        }
      }
    }
  }

  private var audio: some View {
    Group {
      Text("Embedded audio").font(.headline)
      let live = context.presentation.cameras.filter { context.snapshot($0.id)?.running == true }
      if live.isEmpty { Text("No camera is running.").foregroundStyle(.secondary) }
      ForEach(live) { camera in
        VStack(alignment: .leading, spacing: 4) {
          Text(camera.name).font(.callout.weight(.medium))
          UIAudioMeter(audio: camera.audio)
        }
      }
      Text("48 kHz stereo from each input. Not sent through the virtual camera.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

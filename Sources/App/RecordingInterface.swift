import AppKit
import SwiftUI

struct RecordingControls: View {
  @Bindable var model: RecordingModel
  let feeds: [RecordingFeedDescriptor]

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label("Recording", systemImage: "record.circle")
          .font(.caption.weight(.medium))
        Spacer()
        Text(summary)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        Picker("Codec", selection: $model.codec) {
          ForEach(RecordingCodec.allCases, id: \.self) { codec in
            Text(codec.title).tag(codec)
          }
        }
        .labelsHidden()
        .help("Codec for new recordings")

        Picker("Timecode", selection: $model.timecodeMode) {
          ForEach(RecordingTimecodeMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .help(model.timecodeMode.help)
      }

      HStack(spacing: 8) {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        Text("Default")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(model.outputFolder?.path ?? "No output folder selected")
          .font(.caption)
          .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Spacer(minLength: 4)
        Button(model.outputFolder == nil ? "Choose…" : "Change…", action: chooseFolder)
          .controlSize(.small)
        if model.outputFolder != nil {
          Button("Clear", action: { model.outputFolder = nil })
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
      }

      Text("Crash recovery: saves a first fragment after 1 second, then every 10 seconds.")
        .font(.caption2).foregroundStyle(.secondary)
      if !model.interruptedRecordings.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Label("Interrupted recordings found", systemImage: "arrow.counterclockwise.circle")
            .font(.caption.weight(.medium))
          ForEach(model.interruptedRecordings) { take in
            HStack {
              Text(take.title).font(.caption2).lineLimit(1).truncationMode(.middle)
              Spacer()
              if model.recoveringID == take.id { ProgressView().controlSize(.small) }
              Button("Recover") { model.recover(take) }
                .controlSize(.small).disabled(model.recoveringID != nil)
            }
          }
        }
      }
      if let message = model.recoveryMessage {
        Text(message).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if let recovered = model.recoveredURL {
        Button("Show recovered movie in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recovered]) }
          .controlSize(.small)
      }

      HStack(spacing: 7) {
        Button("Record all", systemImage: "record.circle.fill", action: model.recordAll)
          .disabled(!model.canRecordAny)
        Button("Pause all", systemImage: "pause.fill", action: model.pauseAll)
          .disabled(!model.canPauseAny)
        Button("Stop all", systemImage: "stop.fill", action: model.stopAll)
          .disabled(!model.canStopAny)
      }
      .controlSize(.small)

      if model.feeds.isEmpty {
        Text("No feeds configured.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Divider()
        ForEach(model.feeds) { feed in
          RecordingFeedRow(model: model, feed: feed)
          if feed.id != model.feeds.last?.id { Divider() }
        }
      }
    }
    .onAppear { model.updateFeeds(feeds) }
    .onChange(of: feeds) { _, updated in model.updateFeeds(updated) }
  }

  private var summary: String {
    let active = model.feeds.filter(\.isActive).count
    return active == 0 ? "No feeds recording" : "\(active) feed\(active == 1 ? "" : "s") active"
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose default recording folder"
    panel.directoryURL = model.outputFolder
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return }
    model.outputFolder = panel.url
  }
}

private struct RecordingFeedRow: View {
  @Bindable var model: RecordingModel
  let feed: RecordingFeedState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Circle()
          .fill(indicatorColor)
          .frame(width: 7, height: 7)
        Text(feed.name)
          .font(.caption.weight(.medium))
        Text(feed.displayStatus)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        controls
      }
      HStack(spacing: 8) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(model.outputFolder(for: feed.id)?.path ?? "No output folder selected")
          .font(.caption)
          .foregroundStyle(model.outputFolder(for: feed.id) == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        if model.customOutputFolder(for: feed.id) == nil && model.outputFolder != nil {
          Text("Default").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Button(model.customOutputFolder(for: feed.id) == nil ? "Choose…" : "Change…", action: chooseFolder)
          .controlSize(.small)
          .accessibilityLabel("Choose recording folder for \(feed.name)")
        if model.customOutputFolder(for: feed.id) != nil {
          Button("Use default") { model.setOutputFolder(nil, for: feed.id) }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
      }
      .help("Recording folder for \(feed.name). Changes apply to the next recording.")
      let stats = feed.statistics ?? RecordingStatistics()
      HStack(spacing: 18) {
        statistic("Elapsed", stats.elapsedText)
        statistic("File size", stats.sizeText)
        statistic("Dropped frames", "\(stats.droppedVideoFrames)", warning: stats.droppedVideoFrames > 0)
        Spacer(minLength: 0)
      }
      if feed.statistics != nil {
        HStack(spacing: 18) {
          statistic("Encoded", "\(stats.encodedFrames) frames")
          statistic("Encode rate", String(format: "%.1f fps", stats.framesPerSecond))
          statistic("Video bitrate", String(format: "%.1f Mb/s", stats.videoMegabitsPerSecond))
          Spacer(minLength: 0)
        }
        DisclosureGroup("Encoder details") {
          VStack(alignment: .leading, spacing: 5) {
            Text("Encoder: \(stats.hardwareEncoder.map { $0 ? "Hardware accelerated" : "Software" } ?? "Waiting for encoder")")
              .help(stats.encoderID ?? "VideoToolbox reports encoder information after the first frame.")
            Text("Encode latency: \(stats.encoderLatencyMS.map { String(format: "%.1f ms", $0) } ?? "—") · peak \(stats.maxEncoderLatencyMS.map { String(format: "%.1f ms", $0) } ?? "—")")
              .help("Submission to compressed-frame callback, excluding file writing. The current value is smoothed.")
            Text("Writer queue: \(stats.queueSamples)/\(stats.queueCapacity) samples · encoder pending: \(stats.encoderPendingFrames) frames")
            Text("Audio packets dropped: \(stats.droppedAudioPackets) · encoder errors: \(stats.encoderErrors) · writer errors: \(stats.writerErrors)")
            if let url = stats.fileURL {
              Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let message = stats.lastError { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
          }.padding(.top, 3)
        }.font(.caption2).foregroundStyle(.secondary)
      }
      if let error = feed.error {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(feed.name) recording")
    .accessibilityValue(feed.error ?? feed.displayStatus)
  }

  private func statistic(_ title: String, _ value: String, warning: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.caption.monospacedDigit()).foregroundStyle(warning ? .orange : .primary)
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose recording folder for \(feed.name)"
    panel.directoryURL = model.outputFolder(for: feed.id)
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return }
    model.setOutputFolder(panel.url, for: feed.id)
  }

  @ViewBuilder private var controls: some View {
    switch feed.status {
    case .idle:
      Button("Record", systemImage: "record.circle.fill") { model.record(feedID: feed.id) }
        .disabled(model.outputFolder(for: feed.id) == nil)
    case .recording:
      Button("Pause", systemImage: "pause.fill") { model.pause(feedID: feed.id) }
      Button("Stop", systemImage: "stop.fill") { model.stop(feedID: feed.id) }
    case .paused:
      Button("Resume", systemImage: "play.fill") { model.resume(feedID: feed.id) }
      Button("Stop", systemImage: "stop.fill") { model.stop(feedID: feed.id) }
    case .finishing:
      ProgressView().controlSize(.small).help("Finishing the recording file…")
    }
  }

  private var indicatorColor: Color {
    if feed.statistics?.failed == true { return .orange }
    switch feed.status {
    case .idle: return .secondary.opacity(0.55)
    case .recording: return .red
    case .paused: return .orange
    case .finishing: return .secondary
    }
  }
}

/// Each visible surface samples the same process and aggregate GPU history.
/// No resource timer runs while the surface is hidden.
struct AppResourceSummary: View {
  var compact = false
  @State private var usage = AppResourceUsage()
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if compact { Text("Ultracam total").fontWeight(.medium) }
      HStack(spacing: 14) {
      if !compact { Text("Ultracam total").fontWeight(.medium) }
      Text(usage.cpuPercent.map { String(format: "CPU %.1f%%", $0) } ?? "CPU —")
        .help("Total Ultracam process CPU across all threads. 100% is one CPU core; this can exceed 100%. System encoder services run outside this process.")
      Text(String(format: "GPU (video) %.1f%%", usage.gpuPercent))
        .help("Combined busy time of Ultracam's Metal video processing and copy queues over the last second. Overlapping work counts once. Excludes the hardware media encoder and system display compositor.")
      if let bytes = usage.memoryBytes {
        Text("Memory " + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory))
      }
      Spacer(minLength: 0)
      }
    }
    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    .task {
      var sampler = AppResourceSampler()
      while !Task.isCancelled {
        usage = sampler.sample()
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
    }
  }
}

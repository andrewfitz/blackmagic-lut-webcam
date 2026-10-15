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
        .labelsHidden()
        .help("Timecode written into new recordings")
      }

      HStack(spacing: 8) {
        Image(systemName: "folder")
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
    panel.title = "Choose recording folder"
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
        Text(feed.status.title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        controls
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
    .accessibilityValue(feed.error ?? feed.status.title)
  }

  @ViewBuilder private var controls: some View {
    switch feed.status {
    case .idle:
      Button("Record", systemImage: "record.circle.fill") { model.record(feedID: feed.id) }
        .disabled(model.outputFolder == nil)
    case .recording:
      Button("Pause", systemImage: "pause.fill") { model.pause(feedID: feed.id) }
      Button("Stop", systemImage: "stop.fill") { model.stop(feedID: feed.id) }
    case .paused:
      Button("Resume", systemImage: "play.fill") { model.resume(feedID: feed.id) }
      Button("Stop", systemImage: "stop.fill") { model.stop(feedID: feed.id) }
    }
  }

  private var indicatorColor: Color {
    switch feed.status {
    case .idle: return .secondary.opacity(0.55)
    case .recording: return .red
    case .paused: return .orange
    }
  }
}

import AppKit
import SwiftUI

/// The session panel: cameras (only when more than two), output, Program,
/// recording destinations, recent takes, interrupted takes and automation.
/// Rebuilds the context inside its own body so this column refreshes with the models.
struct UISessionSidebarView: View {
  let context: UIContext
  var body: some View { UISessionSidebarViewContent(context: context.current) }
}

struct UISessionSidebarViewContent: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }
  private var presentation: UISessionPresentation { context.presentation }

  var body: some View {
    List {
      if let banner = UIExtensionBanner.state(session.install) {
        Section { UIExtensionBannerView(state: banner, context: context) }
      }
      camerasSection
      outputSection
      recordingSection
      if !session.recentTakes.isEmpty { recentTakesSection }
      if !session.interruptedTakes.isEmpty || session.recoveryMessage != nil { interruptedSection }
      automationSection
    }
    .listStyle(.sidebar)
    .accessibilityLabel("Session")
  }

  // MARK: Cameras

  private var camerasSection: some View {
    Section {
      if presentation.cameras.count > 2 {
        ForEach(presentation.cameras) { camera in
          Button { context.send(.select(cameraID: camera.id)) } label: {
            HStack(spacing: 8) {
              Circle().fill(camera.statusTone == .positive ? Color.green : camera.statusTone.color.opacity(0.7))
                .frame(width: 7, height: 7)
              VStack(alignment: .leading, spacing: 1) {
                Text(camera.name).lineLimit(1).truncationMode(.middle)
                Text(camera.statusBadge).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
              if let badge = camera.tally.badge { UIBadge(text: badge, tone: camera.tally == .onAir ? .onAir : .positive) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(camera.selected ? Color.accentColor.opacity(0.15) : nil)
          .accessibilityLabel(camera.accessibilityLabel)
          .accessibilityAddTraits(camera.selected ? .isSelected : [])
        }
      }
    } header: {
      HStack {
        Text("Cameras · \(presentation.cameras.count)")
        Spacer()
        Button { context.send(.addCamera) } label: { Image(systemName: "plus") }
          .buttonStyle(.borderless)
          .disabled(!session.canEditTopology)
          .help(session.canEditTopology ? "Add Camera" : "Stop all cameras and recordings to add a camera.")
          .accessibilityLabel("Add Camera")
      }
    }
  }

  // MARK: Output

  private var outputSection: some View {
    Section("Output") {
      switch session.outputMode {
      case .program:
        UISidebarRow(symbol: "video.badge.checkmark", title: "Ultracam · Program",
          detail: session.programInUse ? "In use" : "Not in use", positive: session.programInUse)
        LabeledContent("Switching") {
          Text(session.autoSwitching ? (session.autoHold ? "Auto · holding shot" : "Auto · \(session.strategyTitle)") : "Manual")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        if session.autoSwitching {
          UIShotTimerView(shot: session.shot, onAirName: presentation.cameras.first { $0.id == session.onAirID }?.name)
        }
      case .separate:
        ForEach(session.cameras) { camera in
          UISidebarRow(symbol: "video.badge.checkmark", title: "Ultracam · \(camera.name)",
            detail: camera.inUse ? "In use" : "Not in use", positive: camera.inUse)
        }
      }
    }
  }

  // MARK: Recording

  private var recordingSection: some View {
    Section("Recording") {
      let active = session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
      let paused = active.filter { $0.recording.status == .paused }.count
      HStack(spacing: 8) {
        Circle().fill(active.isEmpty ? Color.secondary.opacity(0.4) : .red).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(active.isEmpty ? "Not recording" : paused > 0 ? "\(active.count - paused) recording · \(paused) paused" : "\(active.count) recording")
          Text("\(session.codecTitle) · \(session.timecodeTitle)").font(.caption).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      ForEach(session.drives) { drive in UIDriveRow(drive: drive) }
      HStack(spacing: 6) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(session.defaultFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No default folder")
          .font(.caption).foregroundStyle(session.defaultFolderPath == nil ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
          .help(session.defaultFolderPath ?? "Choose where recordings are saved.")
        Spacer(minLength: 4)
        Button(session.defaultFolderPath == nil ? "Choose…" : "Change…") { context.send(.chooseRecordingFolder(cameraID: nil)) }
          .controlSize(.small)
          .help("Choose the default recording folder. Changes apply to the next take.")
      }
    }
  }

  private var recentTakesSection: some View {
    Section("Recent Takes") {
      ForEach(session.recentTakes) { take in
        HStack(spacing: 8) {
          Image(systemName: "film").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(take.date.formatted(date: .abbreviated, time: .shortened)
              + (take.duration.map { " · \(UIFormat.shortElapsed($0))" } ?? ""))
              .font(.callout).lineLimit(1)
            Text(take.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 4)
          Button { context.send(.revealInFinder(take.url)) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(take.name) in Finder")
        }
        .help(take.url.path)
      }
    }
  }

  private var interruptedSection: some View {
    Section("Interrupted Takes") {
      ForEach(session.interruptedTakes) { take in
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(take.title).font(.callout).lineLimit(1).truncationMode(.middle).help(take.title)
          Spacer(minLength: 4)
          if session.recoveringID == take.id {
            ProgressView().controlSize(.small).accessibilityLabel("Recovering")
          } else {
            Button("Recover") { context.send(.recover(id: take.id)) }
              .controlSize(.small)
              .disabled(session.recoveringID != nil)
              .help("Copy the complete fragments into a separate _Recovered.mov. The original is kept.")
          }
        }
      }
      if let message = session.recoveryMessage {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Automation

  private var automationSection: some View {
    Section("Automation") {
      let automatic = session.cameras.filter(\.automaticStart).map(\.name)
      VStack(alignment: .leading, spacing: 1) {
        Text("Start with camera apps")
        Text(automatic.isEmpty ? "Off" : automatic.joined(separator: ", "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      .help("A camera starts when a meeting app opens its virtual camera and stops when the last app closes. Set it per camera in the inspector.")
      if let status = session.cameras.first(where: { $0.id == session.selectedID })?.automaticStatus {
        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 6) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Backup recording")
          Text("Coming later").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Text("LATER").font(.system(size: 9, weight: .heavy)).foregroundStyle(.purple)
          .padding(.horizontal, 5).frame(height: 15)
          .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
      }
      .foregroundStyle(.secondary)
      .help("Recording that starts with a meeting is designed but not built yet.")
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Pieces

struct UISidebarRow: View {
  let symbol: String
  let title: String
  let detail: String
  var positive = false
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(positive ? Color.green : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1).truncationMode(.middle)
        Text(detail).font(.caption).foregroundStyle(positive ? Color.green : .secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct UIDriveRow: View {
  let drive: UIDrive
  var body: some View {
    let used = drive.totalBytes > 0 ? 1 - Double(drive.availableBytes) / Double(drive.totalBytes) : 0
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "externaldrive").foregroundStyle(.secondary)
        Text(drive.name).lineLimit(1)
        Spacer()
        Text(drive.secondsLeft.map { "\(UIFormat.duration($0)) left" } ?? "\(UIFormat.bytes(drive.availableBytes)) free")
          .font(.caption.monospacedDigit())
          .foregroundStyle((drive.secondsLeft ?? .infinity) < 30 * 60 ? Color.orange : .secondary)
      }
      ProgressView(value: min(1, max(0, used)))
        .progressViewStyle(.linear)
        .tint((drive.secondsLeft ?? .infinity) < 30 * 60 ? .orange : .secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Drive \(drive.name)")
    .accessibilityValue(drive.secondsLeft.map { "\(UIFormat.duration($0)) of recording left" } ?? "\(UIFormat.bytes(drive.availableBytes)) free")
    .help("\(UIFormat.bytes(drive.availableBytes)) free. Time left is estimated from the bitrate of the takes recording to this drive.")
  }
}

/// Length of the current Program shot against the director's minimum, soft maximum and maximum.
struct UIShotTimerView: View {
  let shot: UIShotTiming
  let onAirName: String?
  /// When the current shot started, anchored when the snapshot was taken.
  private let anchor: Date?

  init(shot: UIShotTiming, onAirName: String?) {
    self.shot = shot
    self.onAirName = onAirName
    anchor = shot.currentShot.map { Date().addingTimeInterval(-$0) }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      bar(seconds: anchor.map { max(0, timeline.date.timeIntervalSince($0)) })
    }
  }

  private func bar(seconds: TimeInterval?) -> some View {
    let maximum = max(shot.maximum, 1)
    let fraction = min(1, (seconds ?? 0) / maximum)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("\(onAirName ?? "Program") · shot \(seconds.map { String(format: "%.0f s", $0) } ?? "—")")
        Spacer()
        Text("min \(Int(shot.minimum)) s")
      }
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.12))
          Capsule().fill(LinearGradient(colors: [.green, .green, .yellow], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(2, width * fraction))
          ForEach([shot.minimum, shot.softMaximum], id: \.self) { mark in
            Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: 12)
              .offset(x: width * min(1, mark / maximum) - 0.75)
          }
          Rectangle().fill(Color.red).frame(width: 1.5, height: 12).offset(x: width - 1.5)
        }
      }
      .frame(height: 6)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shot timer")
    .accessibilityValue(seconds.map { String(format: "%.0f seconds; minimum %.0f, soft maximum %.0f, maximum %.0f",
      $0, shot.minimum, shot.softMaximum, shot.maximum) } ?? "No shot")
    .help("Minimum \(Int(shot.minimum)) s · soft maximum \(Int(shot.softMaximum)) s · maximum \(Int(shot.maximum)) s")
  }
}

// MARK: - Camera extension banner

enum UIExtensionBanner: Equatable {
  case unavailable(String)
  case pending(String)
  case needsApproval(String)

  static func state(_ install: UIInstallState) -> UIExtensionBanner? {
    if install.needsApproval { return .needsApproval(install.status) }
    if install.pending { return .pending(install.status.isEmpty ? "Requesting camera activation…" : install.status) }
    if let reason = install.unavailableReason, !install.canRequestChanges { return .unavailable(reason) }
    return nil
  }
}

struct UIExtensionBannerView: View {
  let state: UIExtensionBanner
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch state {
      case .unavailable(let reason):
        Label("Camera needs a signed build", systemImage: "info.circle").font(.callout.weight(.semibold)).lineLimit(2)
        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        Text("Preview and recording still work.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
      case .pending(let status):
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(status).font(.callout).lineLimit(3)
        }
      case .needsApproval(let status):
        Label("Approve the Ultracam camera", systemImage: "exclamationmark.triangle.fill").lineLimit(2)
          .font(.callout.weight(.semibold)).foregroundStyle(.orange)
        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        Button("Open System Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
          }
        }
        .controlSize(.small)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
  }
}

import AppKit
import SwiftUI

/// The app's menu bar menus. State comes from the same presentation as the
/// window, and every item acts through `UISessionBridge.send`, so menus,
/// toolbar and strips stay consistent. Each key equivalent is used once.
struct UICommands: Commands {
  let model: AppModel
  let interface: UIInterfaceState
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  private var bridge: UISessionBridge {
    UISessionBridge.live(model: model, interface: interface, openWindow: { openWindow(id: $0) },
      openSettings: { openSettings() })
  }

  var body: some Commands {
    let bridge = self.bridge
    let session = bridge.snapshot()
    let presentation = UIPresentationBuilder.session(session)
    let selected = presentation.selected
    let selectedSnapshot = session.cameras.first { $0.id == session.selectedID }
    let send: @MainActor (UIAction) -> Void = { bridge.send($0) }

    CommandGroup(after: .appSettings) {
      Toggle("Hide from Dock", isOn: Binding(get: { model.hideFromDock }, set: { model.hideFromDock = $0 }))
    }

    CommandGroup(replacing: .appTermination) {
      Button("Quit Ultracam") {
        model.saveSettings()
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }

    CommandGroup(replacing: .newItem) {
      Button(selected.map { "Load LUT for \($0.name)…" } ?? "Load LUT…") {
        if let selected { send(.chooseLUT(cameraID: selected.id)) }
      }
      .keyboardShortcut("o")
      .disabled(selected == nil)
    }

    CommandMenu("Camera") {
      if let selected {
        Section(selected.name) {
          if selected.canStop {
            Button("Stop \(selected.name)") { send(.stopCamera(cameraID: selected.id)) }
          } else {
            Button("Start \(selected.name)") { send(.startCamera(cameraID: selected.id)) }
              .disabled(!selected.canStart)
          }
          Toggle("Processing", isOn: Binding(get: { selected.processing },
            set: { send(.setProcessing(cameraID: selected.id, $0)) }))
            .keyboardShortcut("b", modifiers: [.command, .shift])
          Toggle("Video Preview", isOn: Binding(get: { selectedSnapshot?.previewEnabled ?? true },
            set: { send(.setPreviewEnabled(cameraID: selected.id, $0)) }))
            .keyboardShortcut("p", modifiers: [.command, .shift])
          Button("Show Inspector") { send(.showInspector(cameraID: selected.id)) }
          Button("Rename \(selected.name)…") { send(.showInspector(cameraID: selected.id)) }
            .disabled(!session.canEditTopology)
        }
      }
      Divider()
      Button(presentation.camerasRunning ? "Stop All Cameras" : "Start All Cameras") {
        send(presentation.camerasRunning ? .stopAllCameras : .startAllCameras)
      }
      .keyboardShortcut(.return, modifiers: .command)
      Divider()
      Section("Select Camera") {
        ForEach(Array(presentation.cameras.prefix(4))) { camera in
          Toggle(camera.name, isOn: Binding(get: { camera.selected }, set: { _ in send(.select(cameraID: camera.id)) }))
            .keyboardShortcut(KeyEquivalent(Character("\(camera.number)")), modifiers: .command)
        }
      }
      Divider()
      Button("Add Camera") { send(.addCamera) }
        .disabled(!session.canEditTopology)
      if let selected {
        // The bridge asks for confirmation before removing.
        Button("Remove \(selected.name)…") { send(.removeCamera(cameraID: selected.id)) }
          .disabled(!session.canEditTopology || presentation.cameras.count < 2)
      }
    }

    CommandMenu("Record") {
      Button(recordTitle(selectedSnapshot)) { send(.toggleRecordingSelected) }
        .keyboardShortcut("r")
        .disabled(!(selected?.recordButtonEnabled ?? false))
      switch presentation.recordControl {
      case .record(_, let enabled):
        Button("Record All") { send(.recordAll) }
          .keyboardShortcut("r", modifiers: [.command, .option])
          .disabled(!enabled)
      case .stop, .stopAll:
        Button("Stop All Recordings") { send(.stopAllRecordings) }
          .keyboardShortcut("r", modifiers: [.command, .option])
      }
      if let selected, selected.pauseTitle != nil {
        Button("\(selected.pauseTitle == "Resume" ? "Resume" : "Pause") Recording \(selected.name)") {
          send(.pauseOrResume(cameraID: selected.id))
        }
      }
      Button("Pause All") { send(.pauseAll) }
        .disabled(!session.cameras.contains { $0.recording.status == .recording })
      Divider()
      Button("Choose Default Folder…") { send(.chooseRecordingFolder(cameraID: nil)) }
      Button("Show Recordings in Finder") { send(.revealRecordings) }
      Button("Recover Interrupted Takes…") {
        // Settings › Recording lists every interrupted take with its own Recover button.
        send(.openSettings)
        NotificationCenter.default.post(name: Notification.Name("UIShowRecovery"), object: nil)
      }
      .disabled(session.interruptedTakes.isEmpty)
    }

    CommandMenu("Program") {
      Picker("Output Mode", selection: Binding(get: { session.outputMode }, set: { send(.setOutputMode($0)) })) {
        Text("Separate Cameras").tag(UIOutputMode.separate)
        Text("Program").tag(UIOutputMode.program)
      }
      .disabled(!session.canEditTopology)
      Divider()
      ForEach(Array(presentation.cameras.prefix(4))) { camera in
        Button("Cut to \(camera.name)") { send(.cut(cameraID: camera.id)) }
          .keyboardShortcut(KeyEquivalent(Character("\(camera.number)")), modifiers: .control)
          .disabled(!camera.cutEnabled)
      }
      Divider()
      Toggle("Automatic Switching", isOn: Binding(get: { session.autoSwitching }, set: { send(.setAutoSwitching($0)) }))
        .keyboardShortcut("a", modifiers: [.control, .option])
        .disabled(session.outputMode != .program)
      Toggle("Hold Current Shot", isOn: Binding(get: { session.autoHold }, set: { send(.setAutoHold($0)) }))
        .disabled(session.outputMode != .program || !session.autoSwitching)
      Picker("Strategy", selection: Binding(get: { session.strategy }, set: { send(.setStrategy($0)) })) {
        ForEach([SwitcherStrategy.manual, .fixedInterval, .naturalTalkingHead], id: \.self) { strategy in
          Text(UIStrategy.title(strategy)).tag(strategy)
        }
      }
      .disabled(session.outputMode != .program)
      let directorEnabled = session.outputMode == .program && session.strategy == .naturalTalkingHead
      Picker("Anchor", selection: Binding(get: { session.anchorID }, set: { send(.setAnchor(cameraID: $0)) })) {
        Text("Automatic").tag(String?.none)
        ForEach(presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
      }
      .disabled(!directorEnabled)
      Picker("Emphasis", selection: Binding(get: { session.emphasisID }, set: { send(.setEmphasis(cameraID: $0)) })) {
        Text("Automatic").tag(String?.none)
        ForEach(presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
      }
      .disabled(!directorEnabled)
    }

    CommandGroup(after: .toolbar) {
      Section("Layout") {
        ForEach(Array(UILayout.allCases.enumerated()), id: \.element) { index, layout in
          Toggle(layout.title, isOn: Binding(get: { presentation.layout == layout }, set: { _ in send(.setLayout(layout)) }))
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            .disabled(!presentation.layouts.contains(layout))
        }
      }
      Button(session.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { send(.toggleSidebar) }
        .keyboardShortcut("s", modifiers: [.command, .control])
      Button(allCollapsed(session) ? "Expand All Strips" : "Collapse All Strips") {
        send(.setAllCollapsed(!allCollapsed(session)))
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      Button(session.inspectorOpen ? "Hide Inspector" : "Show Inspector") { send(.toggleInspector) }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Divider()
      Button("Swap Pictures") { send(.swapPictures) }
        .disabled(presentation.cameras.count < 2 || presentation.layout == .single || presentation.layout == .programView)
      if session.expandedFrom != nil {
        Button("Restore Layout") { send(.restoreLayout) }
      } else {
        Button(selected.map { "Expand \($0.name)" } ?? "Expand Picture") {
          if let selected { send(.expandPicture(cameraID: selected.id)) }
        }
        .disabled(selected == nil || presentation.cameras.count < 2 || presentation.layout == .single)
      }
      Divider()
      if let selected {
        Button("Freeze \(selected.name)") { send(.freeze(cameraID: selected.id)) }
          .keyboardShortcut("f", modifiers: [.control, .option])
        Button("Clean View") { send(.toggleClean(cameraID: selected.id)) }
          .keyboardShortcut("c", modifiers: [.control, .option])
        Toggle("Show Scopes", isOn: Binding(get: { selected.activeTools.contains(.scopes) },
          set: { _ in send(.toggleTool(cameraID: selected.id, .scopes)) }))
          .keyboardShortcut("k", modifiers: [.command, .option])
      }
      Divider()
    }

    // SwiftUI lists the Ultracam and Diagnostics windows in the Window menu itself;
    // ⌘0 is attached to the main Window scene in UltracamApp.

    // macOS lists every open window below; this one item brings back the main window with ⌘0.
    CommandGroup(before: .windowList) {
      Button("Main Window") {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      .keyboardShortcut("0", modifiers: .command)
      Divider()
    }

    CommandGroup(replacing: .help) {
      Button("Ultracam Help") { openWindow(id: "help") }
        .keyboardShortcut("?", modifiers: .command)
    }
  }

  private func recordTitle(_ camera: UICameraSnapshot?) -> String {
    guard let camera else { return "Record" }
    switch camera.recording.status {
    case .recording, .paused: return "Stop Recording \(camera.name)"
    default: return "Record \(camera.name)"
    }
  }

  private func strategy(_ title: String) -> SwitcherStrategy {
    [SwitcherStrategy.manual, .fixedInterval, .naturalTalkingHead, .dynamicAnalysis].first { UIStrategy.title($0) == title } ?? .manual
  }

  private func allCollapsed(_ session: UISessionSnapshot) -> Bool {
    let ids = Set(session.cameras.map(\.id))
    return !ids.isEmpty && ids.isSubset(of: session.collapsed)
  }
}

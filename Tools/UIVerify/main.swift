import AppKit
import MonitorToolsCore
import SwiftUI

// Offscreen verification of the new interface. See README.md.

@MainActor private final class CapturingRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}

@MainActor private struct UIVerify {
  let verifier: Verifier

  // MARK: Rendering

  @discardableResult
  func render<V: View>(_ name: String, _ view: V, size: CGSize, titled: Bool = false, both: Bool = true,
    viewDependent: Bool = true) -> [HostedView] {
    var hosts: [HostedView] = []
    for dark in both ? [false, true] : [false] {
      let hosted = HostedView(view, size: size, dark: dark, titled: titled)
      let file = "\(name)-\(dark ? "dark" : "light").png"
      if let rep = hosted.render() {
        Images.write(rep, to: verifier.pngDirectory.appendingPathComponent(file))
        verifier.savedImage()
        let colors = UISelfTest.distinctColors(rep)
        let dominant = Images.dominantFraction(rep)
        verifier.check("render \(file) is not blank", colors > 12 && dominant < 0.97,
          "\(colors) colors, dominant \(String(format: "%.2f", dominant))", viewDependent: viewDependent)
        if titled {
          // The window chrome alone must not pass: the content area has to draw too.
          let center = Images.dominantFraction(rep, region: 0.5)
          verifier.check("render \(file) draws its content area", center < 0.99,
            "center dominant \(String(format: "%.2f", center))", viewDependent: viewDependent)
        }
        verifier.check("render \(file) has the requested size", rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height),
          "\(rep.pixelsWide)×\(rep.pixelsHigh)")
      } else {
        verifier.check("render \(file)", false, "no bitmap", viewDependent: viewDependent)
      }
      // Close before the next appearance: a second live window of the same split view
      // renders an empty detail column.
      hosted.close()
      hosts.append(hosted)
    }
    return hosts
  }

  func mainWindow(_ context: UIContext) -> some View {
    UIMainWindowView(context: context).toolbar { UIToolbarContent(context: context) }
  }

  // MARK: Fixtures

  func stripFixture(_ state: UIStripState) -> UISessionSnapshot {
    var session = UIFixtures.singleMeeting()
    var camera = UIFixtures.camera(1, recording: .idle, inUse: true)
    switch state {
    case .ready: break
    case .recording:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
    case .paused:
      camera.recording.status = .paused
      camera.recording.elapsed = 252
    case .finishing: camera.recording.status = .finishing
    case .saved:
      camera.recording.savedFileName = "Camera 1_2026-10-21_09-41-03_001.mov"
      camera.recording.savedURL = URL(fileURLWithPath: "/Volumes/8TB/Takes/Camera 1/Camera 1_2026-10-21_09-41-03_001.mov")
      camera.recording.savedDuration = 2292
    case .noFolder: camera.recording.folderPath = nil
    case .failed: camera.recording.error = "The drive was disconnected. Saved up to 00:12:20."
    case .recordingNoSignal:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
      camera.signal = .noSignal
    case .stopped:
      camera.running = false
      camera.signal = .none
      camera.inUse = false
    case .waiting: camera.signal = .noSignal
    case .updating:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
      camera.applying = true
    }
    session.cameras = [camera]
    return session
  }

  // MARK: Screens

  func screens() {
    let fixtures: [(String, UISessionSnapshot)] = [("program-meeting", UIFixtures.programMeeting()),
      ("single-meeting", UIFixtures.singleMeeting()), ("standalone", UIFixtures.standalone()),
      ("four-up", UIFixtures.fourUp()), ("stopped", UIFixtures.stopped())]
    for (name, session) in fixtures {
      for size in [CGSize(width: 1320, height: 860), CGSize(width: 980, height: 680)] {
        let hosts = render("main-\(name)-\(Int(size.width))", mainWindow(.fixture(session)), size: size, titled: true)
        hosts.forEach { $0.close() }
      }
    }
    for layout in UILayout.allCases {
      var session = UIFixtures.programMeeting()
      session.layout = layout
      render("layout-\(layout.rawValue)", mainWindow(.fixture(session)), size: CGSize(width: 1320, height: 860), titled: true)
        .forEach { $0.close() }
    }
    var collapsed = UIFixtures.programMeeting()
    collapsed.collapsed = Set(collapsed.cameras.map(\.id))
    render("main-collapsed", mainWindow(.fixture(collapsed)), size: CGSize(width: 1320, height: 860), titled: true).forEach { $0.close() }
    var inspector = UIFixtures.programMeeting()
    inspector.inspectorOpen = true
    // `.inspector` inside a bare NSHostingView (no SwiftUI scene) throws during AppKit layout, so the
    // whole-window inspector render is verified by the in-app self-test instead. RENDER_INSPECTOR=1 tries it here.
    if ProcessInfo.processInfo.environment["RENDER_INSPECTOR"] == "1" {
      render("main-inspector", UIMainWindowView(context: .fixture(inspector)), size: CGSize(width: 1600, height: 900))
        .forEach { $0.close() }
    }

    // Components
    let meeting = UIContext.fixture(UIFixtures.programMeeting())
    if let first = meeting.presentation.cameras.first {
      render("component-camera-column", UICameraColumnView(camera: first, context: meeting), size: CGSize(width: 560, height: 720))
        .forEach { $0.close() }
    }
    for state in [UIStripState.ready, .recording, .paused, .finishing, .saved, .noFolder, .failed, .recordingNoSignal, .stopped,
      .waiting, .updating] {
      var session = stripFixture(state)
      let derived = session.cameras.first.map(UIPresentationBuilder.stripState(for:))
      verifier.check("strip fixture derives \(state.rawValue)", derived == state, "derived \(String(describing: derived))")
      for collapsedStrip in [false, true] {
        session.collapsed = collapsedStrip ? [session.cameras[0].id] : []
        let context = UIContext.fixture(session)
        guard let camera = context.presentation.cameras.first else { continue }
        render("strip-\(state.rawValue)\(collapsedStrip ? "-collapsed" : "")", UIChannelStripView(camera: camera, context: context),
          size: CGSize(width: 560, height: collapsedStrip ? 52 : 230)).forEach { $0.close() }
      }
    }
    render("component-sidebar", UISessionSidebarView(context: meeting), size: CGSize(width: 260, height: 860)).forEach { $0.close() }
    render("component-inspector", UIInspectorView(context: meeting), size: CGSize(width: 320, height: 860)).forEach { $0.close() }
    render("component-status-bar", UIStatusBarView(context: meeting), size: CGSize(width: 1320, height: 40)).forEach { $0.close() }
    render("component-program-view", UIProgramView(context: meeting), size: CGSize(width: 1060, height: 800)).forEach { $0.close() }
  }

  // MARK: Accessibility and interaction

  func names(_ nodes: [AXNode]) -> [String] { nodes.map(\.text) }

  func contains(_ nodes: [AXNode], _ needle: String) -> Bool {
    nodes.contains { $0.label == needle || $0.title == needle || $0.value == needle || $0.text.contains(needle) }
  }

  func accessibility() {
    let session = UIFixtures.programMeeting()
    let context = UIContext.fixture(session)
    let hosted = HostedView(mainWindow(context), size: CGSize(width: 1320, height: 860), dark: false, titled: true)
    defer { hosted.close() }
    let nodes = Accessibility.nodes(in: hosted.host)
    let dump = nodes.map { "\($0.role)\t\($0.text)\t\($0.enabled ? "" : "disabled")" }.joined(separator: "\n")
    try? dump.write(to: verifier.pngDirectory.deletingLastPathComponent().appendingPathComponent("accessibility-program-meeting.tsv"),
      atomically: true, encoding: .utf8)
    for label in ["Camera 1", "Camera 2", "On Air", "Stop Recording", "Stop Camera 1", "Processing", "LUT", "1080p",
      "Ultracam · Program · in use", "Cut to Camera 2"] {
      verifier.check("accessibility contains \"\(label)\"", contains(nodes, label), "", viewDependent: true)
    }
    verifier.check("no app names in accessibility text", !nodes.contains { node in
      ["Zoom", "Teams", "FaceTime", "Webex"].contains { node.text.contains($0) }
    })

    let stopped = HostedView(mainWindow(.fixture(UIFixtures.stopped())), size: CGSize(width: 1320, height: 860), dark: true, titled: true)
    defer { stopped.close() }
    let stoppedNodes = Accessibility.nodes(in: stopped.host)
    verifier.check("stopped window offers Start Camera", contains(stoppedNodes, "Start Camera") || contains(stoppedNodes, "Start Camera 1"),
      "", viewDependent: true)
  }

  func interactions() {
    let log = ActionLog()
    let session = UIFixtures.programMeeting()
    let context = UIContext.fixture(session) { log.append($0) }
    let presentation = context.presentation

    // Picture press selects and never cuts (D1).
    for camera in presentation.cameras {
      let hosted = HostedView(UICameraPictureView(camera: camera, context: context), size: CGSize(width: 520, height: 292), dark: false)
      let nodes = Accessibility.nodes(in: hosted.host)
      let picture = nodes.first { $0.label == camera.accessibilityLabel }
      verifier.check("\(camera.name) picture is an accessibility element", picture != nil,
        names(nodes).prefix(12).joined(separator: "; "), viewDependent: true)
      if let picture {
        log.clear()
        _ = Accessibility.press(picture)
        hosted.settle()
        verifier.check("pressing \(camera.name)'s picture selects it", log.actions.contains(.select(cameraID: camera.id)),
          "\(log.actions)", viewDependent: true)
        verifier.check("pressing \(camera.name)'s picture never cuts", !log.actions.contains { if case .cut = $0 { return true }; return false },
          "\(log.actions)")
      }
      hosted.close()
    }

    // Strip controls.
    func pressInStrip(_ camera: UICameraPresentation, _ label: String, expect: UIAction) {
      let hosted = HostedView(UIChannelStripView(camera: camera, context: context), size: CGSize(width: 560, height: 230), dark: false)
      defer { hosted.close() }
      let nodes = Accessibility.nodes(in: hosted.host)
      guard let node = nodes.first(where: { ($0.label == label || $0.title == label) && !$0.role.contains("Menu") && !$0.role.contains("PopUp") }) else {
        verifier.check("strip of \(camera.name) has \"\(label)\"", false, names(nodes).prefix(20).joined(separator: "; "), viewDependent: true)
        return
      }
      log.clear()
      let pressed = Accessibility.press(node)
      hosted.settle()
      verifier.check("strip \(camera.name) \"\(label)\" sends \(expect)", log.actions.contains(expect),
        "pressed=\(pressed) actions=\(log.actions)", viewDependent: true)
    }
    let one = presentation.cameras[0]
    let two = presentation.cameras[1]
    pressInStrip(one, "Stop Recording", expect: .toggleRecording(cameraID: one.id))
    pressInStrip(one, "Pause", expect: .pauseOrResume(cameraID: one.id))
    pressInStrip(one, "Stop Camera 1", expect: .stopCamera(cameraID: one.id))
    pressInStrip(one, "1080p", expect: .setEffect(cameraID: one.id, index: 1, false))
    pressInStrip(two, "4:2:0", expect: .setEffect(cameraID: two.id, index: 2, false))
    // Camera 2 has no LUT loaded, so its LUT chip is disabled and must not act.
    do {
      let hosted = HostedView(UIChannelStripView(camera: two, context: context), size: CGSize(width: 560, height: 230), dark: false)
      let lut = Accessibility.nodes(in: hosted.host).first { $0.label == "LUT" }
      verifier.check("Camera 2 LUT chip is disabled without a LUT", lut?.enabled == false, "", viewDependent: true)
      if let lut {
        log.clear()
        _ = Accessibility.press(lut)
        hosted.settle()
        verifier.check("disabled LUT chip sends nothing", log.actions.isEmpty, "\(log.actions)")
      }
      hosted.close()
    }
    pressInStrip(two, "Collapse Camera 2", expect: .toggleCollapsed(cameraID: two.id))

    // Toolbar controls (rendered standalone; the window toolbar hosts the same views).
    func pressIn<V: View>(_ name: String, _ view: V, _ label: String, expect: UIAction) {
      let hosted = HostedView(view, size: CGSize(width: 520, height: 60), dark: false)
      defer { hosted.close() }
      let nodes = Accessibility.nodes(in: hosted.host)
      guard let node = nodes.first(where: { $0.label == label || $0.title == label }) else {
        verifier.check("\(name) has \"\(label)\"", false, names(nodes).prefix(20).joined(separator: "; "), viewDependent: true)
        return
      }
      log.clear()
      _ = Accessibility.press(node)
      hosted.settle()
      verifier.check("\(name) \"\(label)\" sends \(expect)", log.actions.contains(expect), "\(log.actions)", viewDependent: true)
    }
    pressIn("toolbar cut group", UIToolbarCutGroup(context: context), "Cut to Camera 2", expect: .cut(cameraID: two.id))
    pressIn("toolbar record control", UIToolbarRecordControl(context: context), "Stop all 2 recordings, 12:31", expect: .stopAllRecordings)
    let idle = UIContext.fixture(UIFixtures.stopped()) { log.append($0) }
    let idleCamera = idle.presentation.cameras[0]
    let hosted = HostedView(UIChannelStripView(camera: idleCamera, context: idle), size: CGSize(width: 560, height: 230), dark: false)
    let idleNodes = Accessibility.nodes(in: hosted.host)
    if let start = idleNodes.first(where: { $0.label == "Start Camera 1" || $0.title == "Start Camera" }) {
      log.clear()
      _ = Accessibility.press(start)
      hosted.settle()
      verifier.check("stopped strip Start sends startCamera", log.actions.contains(.startCamera(cameraID: idleCamera.id)), "\(log.actions)",
        viewDependent: true)
    } else {
      verifier.check("stopped strip has Start", false, names(idleNodes).prefix(20).joined(separator: "; "), viewDependent: true)
    }
    if let record = idleNodes.first(where: { $0.label == "Record" }) {
      verifier.check("record is disabled when the camera is stopped", !record.enabled, "", viewDependent: true)
    }
    hosted.close()
  }

  // MARK: Real model bridge

  func bridge() throws {
    let suiteName = "org.ultracam.ui-verify.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { verifier.check("defaults suite", false); return }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettingsStore(defaults: defaults)
    let alpha = FeedID(rawValue: "ui-verify-alpha")
    let beta = FeedID(rawValue: "ui-verify-beta")
    settings.saveSnapshot(AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: alpha, name: "Camera 1", selectedDevice: "ui-verify-device-a", applyLUT: false, automaticFeed: false),
      FeedDescriptor(id: beta, name: "Camera 2", selectedDevice: "ui-verify-device-b", applyLUT: false, automaticFeed: false),
    ], selectedFeedID: alpha, outputMode: .separateCameras))
    let model = AppModel(settingsStore: settings, registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: CapturingRegistryPublisher(), recordingFolderStore: RecordingFolderStore(defaults: defaults))
    let interface = UIInterfaceState(defaults: defaults)
    interface.alertsDisabled = true
    let bridge = UISessionBridge(model: model, interface: interface)

    let snapshot = bridge.snapshot()
    verifier.check("bridge: two cameras with names", snapshot.cameras.map(\.name) == ["Camera 1", "Camera 2"], "\(snapshot.cameras.map(\.name))")
    verifier.check("bridge: selection", snapshot.selectedID == alpha.rawValue)
    verifier.check("bridge: separate mode", snapshot.outputMode == .separate)
    verifier.check("bridge: idle recording", snapshot.cameras.allSatisfy { $0.recording.status == .idle })
    verifier.check("bridge: stopped cameras have no signal", snapshot.cameras.allSatisfy { !$0.running && $0.signal == .none })
    verifier.check("bridge: presentation builds", bridge.presentation().cameras.count == 2)

    bridge.perform(.select(cameraID: beta.rawValue))
    verifier.check("bridge: select", model.selectedFeedID == beta && bridge.snapshot().selectedID == beta.rawValue)
    bridge.perform(.select(cameraID: alpha.rawValue))

    bridge.perform(.setLayout(.single))
    verifier.check("bridge: layout", interface.layout == .single && bridge.snapshot().layout == .single)
    verifier.check("bridge: layout persists", UIInterfaceState(defaults: defaults).layout == .single)
    bridge.perform(.setLayout(.programView))
    verifier.check("bridge: Program View falls back in Separate mode", bridge.snapshot().layout == .sideBySide)
    bridge.perform(.setAllCollapsed(true))
    verifier.check("bridge: collapse all", interface.collapsed == [alpha.rawValue, beta.rawValue])
    bridge.perform(.toggleCollapsed(cameraID: alpha.rawValue))
    verifier.check("bridge: toggle collapsed", interface.collapsed == [beta.rawValue])
    bridge.perform(.setAllCollapsed(false))
    verifier.check("bridge: expand all", interface.collapsed.isEmpty)
    bridge.perform(.toggleSidebar)
    verifier.check("bridge: toggle sidebar", interface.sidebarVisible == false)
    bridge.perform(.toggleInspector)
    verifier.check("bridge: toggle inspector", interface.inspectorOpen)

    // Per-camera settings on the camera that isn't selected must persist without selecting it.
    let downscaleBefore = model.descriptor(for: beta)?.downscale ?? true
    bridge.perform(.setEffect(cameraID: beta.rawValue, index: 1, !downscaleBefore))
    verifier.check("bridge: effect on non-selected camera keeps selection", model.selectedFeedID == alpha)
    let reloaded = AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first { $0.id == beta }
    verifier.check("bridge: effect on non-selected camera persists", reloaded?.downscale == !downscaleBefore,
      "downscale \(String(describing: reloaded?.downscale))")
    verifier.check("bridge: snapshot reflects the effect", bridge.snapshot().cameras[1].effects[1] == !downscaleBefore)
    bridge.perform(.setProcessing(cameraID: beta.rawValue, false))
    verifier.check("bridge: processing persists", AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first { $0.id == beta }?.pipelineEnabled == false)
    verifier.check("bridge: snapshot reflects processing", bridge.snapshot().cameras[1].processing == false)
    bridge.perform(.setAutomaticStart(cameraID: beta.rawValue, true))
    verifier.check("bridge: automatic start persists", model.descriptor(for: beta)?.automaticFeed == true)
    bridge.perform(.setAutomaticStart(cameraID: beta.rawValue, false))
    bridge.perform(.setEffect(cameraID: alpha.rawValue, index: 2, false))
    verifier.check("bridge: effect on selected camera", model.configuration.convertTo420 == false && bridge.snapshot().cameras[0].effects[2] == false)
    bridge.perform(.setGamut(cameraID: beta.rawValue, "S-Gamut3 / S-Log3"))
    verifier.check("bridge: gamut", model.descriptor(for: beta)?.gamut == "S-Gamut3 / S-Log3")

    // Stopping cameras that aren't running does nothing.
    bridge.perform(.stopCamera(cameraID: beta.rawValue))
    bridge.perform(.stopCamera(cameraID: alpha.rawValue))
    bridge.perform(.stopAllCameras)
    verifier.check("bridge: stop on stopped cameras is a no-op", !model.running && !model.isCameraRunning(beta))
    bridge.send(.stopCamera(cameraID: beta.rawValue))
    verifier.check("bridge: no confirmation for an idle camera", interface.confirmation == nil)

    // Topology while idle.
    bridge.perform(.setOutputMode(.program))
    verifier.check("bridge: output mode while idle", model.outputMode == .program && bridge.snapshot().outputMode == .program)
    bridge.perform(.setLayout(.programView))
    verifier.check("bridge: Program View in Program mode", bridge.snapshot().layout == .programView)
    bridge.perform(.setOutputMode(.separate))
    bridge.perform(.addCamera)
    verifier.check("bridge: add camera", model.feedDescriptors.count == 3)
    if let added = model.feedDescriptors.last?.id {
      bridge.perform(.renameCamera(cameraID: added.rawValue, name: "Wide"))
      verifier.check("bridge: rename", model.descriptor(for: added)?.name == "Wide")
      bridge.perform(.removeCamera(cameraID: added.rawValue))
      verifier.check("bridge: remove", model.feedDescriptors.count == 2)
    }
    bridge.perform(.setAutoHold(true))
    verifier.check("bridge: auto hold", model.switcherSettings.naturalTalkingHead.manualHold)
    bridge.perform(.setAutoHold(false))
    bridge.perform(.setAutoSwitching(true))
    verifier.check("bridge: auto switching", model.switcherSettings.automatic && bridge.snapshot().autoSwitching)
    bridge.perform(.setStrategy(.naturalTalkingHead))
    verifier.check("bridge: strategy", bridge.snapshot().strategyTitle == "Natural talking head")
    bridge.perform(.setAutoSwitching(false))

    // Settings and Diagnostics with the real model.
    render("settings-general", UISettingsGeneralPane(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-recording", UISettingsRecordingPane(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-camera", UISettingsCameraPane(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-switcher", UISettingsSwitcherPane(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-monitor", UISettingsMonitorPane(), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-advanced", UISettingsAdvancedPane(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("settings-window", UISettingsView(model: model), size: CGSize(width: 640, height: 640)).forEach { $0.close() }
    render("diagnostics", UIDiagnosticsView(model: model), size: CGSize(width: 1100, height: 760)).forEach { $0.close() }
    interface.inspectorOpen = false
    interface.sidebarVisible = true
    let live = UISessionBridge.live(model: model, interface: interface).context()
    render("main-live-model", mainWindow(live), size: CGSize(width: 1320, height: 860), titled: true).forEach { $0.close() }
  }

  // MARK: Menu bar

  func menuItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
    items.flatMap { item in [item] + menuItems(item.submenu?.items ?? []) }
  }

  func menuBar() {
    let fixtures: [(String, UISessionSnapshot)] = [("program-meeting", UIFixtures.programMeeting()),
      ("single-meeting", UIFixtures.singleMeeting()), ("standalone", UIFixtures.standalone()),
      ("four-up", UIFixtures.fourUp()), ("stopped", UIFixtures.stopped())]
    for (name, session) in fixtures {
      let presentation = UIPresentationBuilder.session(session)
      let topLevel = UIMenuBarController.buildItems(presentation: presentation, session: session, inputs: UIFixtures.inputs,
        stats: "CPU 31% · GPU 18%", target: nil, previewItem: nil, showLivePreview: false)
      let topLevelIDs = Set(topLevel.map(ObjectIdentifier.init))
      let items = menuItems(topLevel)
      let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
      try? titles.joined(separator: "\n").write(to: verifier.pngDirectory.deletingLastPathComponent()
        .appendingPathComponent("menubar-\(name).txt"), atomically: true, encoding: .utf8)
      verifier.check("menu bar \(name): has rows", items.count > 5, "\(items.count)")
      for required in ["Settings…", "Quit Ultracam"] {
        verifier.check("menu bar \(name): \(required)", titles.contains { $0.hasPrefix(required) }, titles.joined(separator: " | "))
      }
      verifier.check("menu bar \(name): opens the window", titles.contains { $0.hasPrefix("Open Ultracam") || $0.hasPrefix("Show Ultracam") },
        titles.joined(separator: " | "))
      // Cuts only come from explicit "Cut to …" rows (D1).
      for item in items {
        let cuts = UIMenuBarController.commands(for: item).contains { command in
          if case .action(.cut) = command { return true }
          if case .action(.cutNumber) = command { return true }
          return false
        }
        if cuts {
          verifier.check("menu bar \(name): cut lives on a Cut row (\(item.title))", item.title.hasPrefix("Cut to"))
          // The top-level cut rows carry ⌃n; the copy inside each camera's submenu has
          // no shortcut, so every key equivalent stays unique.
          if topLevelIDs.contains(ObjectIdentifier(item)) {
            verifier.check("menu bar \(name): cut row has ⌃n", item.keyEquivalentModifierMask.contains(.control) && !item.keyEquivalent.isEmpty,
              "\(item.title) key=\(item.keyEquivalent)")
          }
        }
      }
      if session.outputMode == .separate {
        verifier.check("menu bar \(name): no cut rows in Separate mode", !titles.contains { $0.hasPrefix("Cut to") })
      } else {
        verifier.check("menu bar \(name): cut row for the off-air camera", titles.contains("Cut to Camera 2"), titles.joined(separator: " | "))
      }
      let shortcuts = items.filter { !$0.keyEquivalent.isEmpty }.map {
        UISelfTest.shortcut(key: $0.keyEquivalent, modifiers: $0.keyEquivalentModifierMask)
      }
      let duplicates = Dictionary(grouping: shortcuts, by: { $0 }).filter { $0.value.count > 1 }.keys
      verifier.check("menu bar \(name): no duplicate shortcuts", duplicates.isEmpty, duplicates.sorted().joined(separator: ", "))
      verifier.check("menu bar \(name): no consumer app names", !titles.contains { $0.contains("Zoom") || $0.contains("Teams") })
    }
    for icon in [UIMenuBarIcon.stopped, .waiting, .live, .bypass, .recording, .attention] {
      let image = UIMenuBarController.image(for: icon)
      verifier.check("menu bar icon \(icon.rawValue) renders", image != nil)
      verifier.check("menu bar icon \(icon.rawValue) is a template", image?.isTemplate == true)
    }
  }
}

// MARK: Entry

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : NSTemporaryDirectory() + "ultracam-ui-verify"
let strict = ProcessInfo.processInfo.environment["STRICT"] != "0"

let exitCode: Int32 = MainActor.assumeIsolated {
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.finishLaunching()
  // SwiftUI builds its accessibility tree only when an assistive client is active.
  // Enhanced user interface mode is what such a client sets; no permission is needed.
  NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
  let verifier = Verifier(output: URL(fileURLWithPath: outputPath, isDirectory: true), strict: strict)
  let run = UIVerify(verifier: verifier)
  let started = Date()
  run.screens()
  run.accessibility()
  run.interactions()
  do { try run.bridge() } catch { verifier.check("bridge tests threw", false, "\(error)") }
  run.menuBar()
  print("""

  UI verify \(strict ? "(strict)" : "(tolerant)"): \(verifier.passed) passed, \(verifier.failed) failed, \(verifier.pending) pending, \
  \(verifier.images) images in \(String(format: "%.0f", Date().timeIntervalSince(started))) s
  Images: \(verifier.pngDirectory.path)
  """)
  for failure in verifier.failures { print("  FAIL \(failure)") }
  return verifier.failed == 0 ? 0 : 1
}
exit(exitCode)

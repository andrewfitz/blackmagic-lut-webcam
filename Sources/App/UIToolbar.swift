import SwiftUI

/// Main window toolbar: Program cuts and Auto, layout, collapse, cameras,
/// the record control (always with a verb) and the inspector toggle.
struct UIToolbarContent: ToolbarContent {
  let context: UIContext

  private var presentation: UISessionPresentation { context.presentation }

  var body: some ToolbarContent {
    if presentation.outputMode == .program && !presentation.cutButtons.isEmpty {
      ToolbarItem(placement: .principal) {
        UIToolbarCutGroup(context: context)
      }
    }

    // Order matters: when the window narrows, macOS moves the trailing items into
    // the overflow menu first. Cameras and the record control come first so they stay
    // visible; layout, collapse and the inspector (all also in the View menu) go first.
    ToolbarItem(placement: .primaryAction) {
      Button {
        context.send(presentation.camerasRunning ? .stopAllCameras : .startAllCameras)
      } label: {
        Label(presentation.camerasControlTitle, systemImage: presentation.camerasRunning ? "stop.fill" : "play.fill")
          .labelStyle(.titleAndIcon)
      }
      .help(presentation.camerasRunning
        ? "Stop capture and output for every camera (⌘↩). Asks first if a recording or on-air camera is affected."
        : "Start every camera (⌘↩).")
    }

    ToolbarItem(placement: .primaryAction) {
      UIToolbarRecordControl(context: context)
    }

    if context.session.expandedFrom != nil {
      ToolbarItem(placement: .primaryAction) {
        Button {
          context.send(.restoreLayout)
        } label: {
          Label("Restore Layout", systemImage: "arrow.down.right.and.arrow.up.left")
            .labelStyle(.titleAndIcon)
        }
        .help("Return to the layout you expanded this picture from")
      }
    }

    // One camera has only the single layout, so the picker appears with a second camera.
    if presentation.layouts.count > 1 {
      ToolbarItem(placement: .primaryAction) {
        Picker("Layout", selection: layoutBinding) {
          ForEach(presentation.layouts, id: \.self) { layout in
            Label(layout.title, systemImage: layout.symbol).tag(layout)
          }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Layout (⌥⌘1–⌥⌘4)")
      }
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        context.send(.setAllCollapsed(!allCollapsed))
      } label: {
        Label(allCollapsed ? "Expand All Strips" : "Collapse All Strips",
          systemImage: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
      }
      .help(allCollapsed ? "Expand All Strips (⌥⌘S)" : "Collapse All Strips (⌥⌘S)")
      .disabled(presentation.layout == .fourUp || presentation.layout == .programView)
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        context.send(.toggleInspector)
      } label: {
        Label("Inspector", systemImage: "sidebar.right")
      }
      .help("Show or hide the inspector for the selected camera (⌥⌘I)")
    }
  }

  private var allCollapsed: Bool {
    let ids = Set(presentation.cameras.map(\.id))
    return !ids.isEmpty && ids.isSubset(of: context.session.collapsed)
  }

  private var layoutBinding: Binding<UILayout> {
    Binding(get: { presentation.layout }, set: { context.send(.setLayout($0)) })
  }
}

/// Program cut buttons (red = on air, green outline = cut pending) and the Auto switch.
struct UIToolbarCutGroup: View {
  let context: UIContext

  var body: some View {
    HStack(spacing: 6) {
      ForEach(context.presentation.cutButtons) { button in
        cutButton(button)
      }
      Divider().frame(height: 18)
      Toggle(isOn: Binding(get: { context.presentation.autoSwitching }, set: { context.send(.setAutoSwitching($0)) })) {
        Label("Auto", systemImage: "wand.and.sparkles")
      }
      .toggleStyle(.button)
      .help("Automatic switching (⌃⌥A)")
    }
  }

  @ViewBuilder private func cutButton(_ button: UICutButton) -> some View {
    let title = HStack(spacing: 4) { Text("\(button.number)").monospacedDigit().fontWeight(.bold); Text(button.name) }
    if button.onAir {
      Button { context.send(.cut(cameraID: button.id)) } label: { title }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .help("\(button.name) is on air")
        .accessibilityLabel("\(button.name), on air")
    } else {
      Button { context.send(.cut(cameraID: button.id)) } label: { title }
        .buttonStyle(.bordered)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(button.pending ? Color.green : .clear, lineWidth: 1.5))
        .disabled(!button.enabled)
        .help(button.pending ? "Cut to \(button.name) is pending" : "Cut to \(button.name) (⌃\(button.number))")
        .accessibilityLabel(button.pending ? "\(button.name), cut pending" : "Cut to \(button.name)")
    }
  }
}

/// Record control: "Record All", "Stop All (2) 12:31" or "Stop Recording 12:31".
struct UIToolbarRecordControl: View {
  let context: UIContext

  var body: some View {
    let control = context.presentation.recordControl
    switch control {
    case .record(let all, let enabled):
      Button {
        context.send(all ? .recordAll : .toggleRecordingSelected)
      } label: {
        Label(control.title, systemImage: "record.circle")
          .labelStyle(.titleAndIcon)
      }
      .disabled(!enabled)
      .help(all ? "Record every running camera (⌥⌘R)" : "Record (⌘R)")
    case .stop(let elapsed):
      Button {
        context.send(.toggleRecordingSelected)
      } label: {
        Label { HStack(spacing: 4) { Text("Stop Recording"); Text(elapsed).monospacedDigit() } } icon: { Image(systemName: "stop.fill") }
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .help("Stop Recording (⌘R)")
    case .stopAll(let count, let elapsed):
      Button {
        context.send(.stopAllRecordings)
      } label: {
        Label { HStack(spacing: 4) { Text("Stop All (\(count))"); Text(elapsed).monospacedDigit() } } icon: { Image(systemName: "stop.fill") }
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .help("Stop All Recordings (⌥⌘R)")
      .accessibilityLabel("Stop all \(count) recordings, \(elapsed)")
    }
  }
}

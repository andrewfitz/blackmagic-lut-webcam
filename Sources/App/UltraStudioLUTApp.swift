import AppKit
import SwiftUI

@main
struct UltraStudioLUTApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    // A single window keeps the main native video layer attached to one view.
    Window("UltraStudio LUT", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 850, minHeight: 590)
    }
    .defaultSize(width: 1080, height: 700)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Feed") {
        Button(model.running ? "Stop feed" : "Start feed") {
          if model.running { model.stop() } else { model.start() }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.running && !model.canStartFeed)
        Divider()
        Toggle("Processing enabled", isOn: $model.pipelineEnabled)
          .keyboardShortcut("b", modifiers: [.command, .shift])
        Toggle("Video preview", isOn: $model.previewEnabled)
          .keyboardShortcut("p", modifiers: [.command, .shift])
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit UltraStudio LUT") {
          model.saveSettings()
          model.stop()
          NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
      }
    }

    MenuBarExtra {
      MenuBarInterface(model: model)
    } label: {
      MenuBarStatusIcon(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

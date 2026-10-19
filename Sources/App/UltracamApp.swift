import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    let hideFromDock = AppSettingsStore().hideFromDock
    NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
  }
}

@main
struct UltracamApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    // A single window keeps the main native video layer attached to one view.
    Window("Ultracam", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 850, minHeight: 590)
    }
    .defaultSize(width: 1080, height: 700)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appSettings) {
        Toggle("Hide from Dock", isOn: $model.hideFromDock)
      }
      CommandMenu("Feed") {
        Button(model.running ? "Stop feed" : "Start feed") {
          if model.running { model.stop() } else { model.start() }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(model.automaticFeedEnabled || (!model.running && !model.canStartFeed))
        Divider()
        Toggle("Start when camera is in use", isOn: $model.automaticFeedEnabled)
        Toggle("Processing enabled", isOn: $model.pipelineEnabled)
          .keyboardShortcut("b", modifiers: [.command, .shift])
        Toggle("Video preview", isOn: $model.previewEnabled)
          .keyboardShortcut("p", modifiers: [.command, .shift])
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit Ultracam") {
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

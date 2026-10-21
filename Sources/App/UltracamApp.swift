import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let hideFromDock = AppSettingsStore().hideFromDock
    NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.recordingModel.hasActiveRecordings else { return .terminateNow }
    model.saveSettings()
    model.stop()
    model.recordingModel.stopAll {
      DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
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
        .onAppear { appDelegate.model = model }
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

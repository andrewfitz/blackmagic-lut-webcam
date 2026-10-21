import AppKit
import SwiftUI

/// The app's long-lived models, shared by the scenes, the menu bar item and the self-test.
@MainActor enum UIAppEnvironment {
  static let model = AppModel()
  static let interface = UIInterfaceState()
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var menuBar: UIMenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let hideFromDock = AppSettingsStore().hideFromDock
    NSApplication.shared.setActivationPolicy(hideFromDock ? .accessory : .regular)
    let model = UIAppEnvironment.model
    self.model = model
    menuBar = UIMenuBarController(model: model, interface: UIAppEnvironment.interface)
    // The self-test lives in its own file and is found through the Objective-C
    // runtime, so the app builds with or without it.
    if CommandLine.arguments.contains("--ui-self-test"),
      let runner = NSClassFromString("UISelfTestRunner") as? NSObject.Type {
      _ = runner.perform(NSSelectorFromString("run"))
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.recordingModel.hasActiveRecordings else { return .terminateNow }
    model.saveSettings()
    model.stopAllCameras()
    model.recordingModel.stopAll {
      DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }
}

@main
struct UltracamApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let model = UIAppEnvironment.model
  private let interface = UIAppEnvironment.interface

  var body: some Scene {
    // A single main window keeps the selected camera's native video layer attached to one view.
    Window("Ultracam", id: "main") {
      UILiveRoot(model: model, interface: interface) { context in
        UIMainWindowView(context: context)
          .toolbar { UIToolbarContent(context: context) }
      }
    }
    .defaultSize(width: 1320, height: 860)
    .windowToolbarStyle(.unified)
    .commands { UICommands(model: model, interface: interface) }

    Window("Diagnostics", id: "diagnostics") {
      UIDiagnosticsView(model: model)
    }
    .defaultSize(width: 1100, height: 760)

    Settings {
      UISettingsView(model: model)
    }
  }
}

import AppKit
import SwiftUI

struct MenuBarStatusIcon: View {
  let model: AppModel

  var body: some View {
    let established = model.running && model.update.pipelineEnabledApplied != nil
    Image(systemName: established ? (model.update.pipelineEnabledApplied == true ? "video.fill" : "arrow.right.square") : "video")
      .accessibilityLabel(!established ? "Ultracam feed is stopped or starting"
        : model.update.pipelineEnabledApplied == true ? "Ultracam processing is active" : "Ultracam complete bypass is active")
  }
}

// MenuBarExtra's native window supplies menu bar positioning, dismissal and
// material. Its renderer is independent of the main window's video layer.
struct MenuBarInterface: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          FeedStateLabel(model: model)
          CameraConnectionLabel(model: model)
        }
        Spacer()
        StartStopButton(model: model).controlSize(.small)
      }
      PipelineEnableControl(model: model)
      AutomaticFeedControl(model: model)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          MonitorCompactPreview(coordinator: model.monitorCoordinator, model: model)
          PreviewErrorNotice(model: model)
          Divider()
          PipelineControls(model: model, compact: true)
          Divider()
          LUTControls(model: model, compact: true)
          Divider()
          MultiCameraControls(model: model)
          DisclosureGroup("Feed details") {
            VStack(alignment: .leading, spacing: 12) {
              InputDeviceControl(model: model)
              FeedMetadata(model: model)
              CameraOutputControls(model: model)
              FeedDiagnostics(model: model, compact: true)
            }.padding(.top, 6)
          }.font(.caption)
          FeedNotice(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
      }
      .scrollBounceBehavior(.basedOnSize)
      Divider()
      AppResourceSummary(compact: true)
      Toggle("Hide from Dock", isOn: $model.hideFromDock)
        .toggleStyle(.checkbox)
        .font(.caption)
        .help("Keep Ultracam in the menu bar without showing its Dock icon.")
      HStack {
        Button("Open window", systemImage: "macwindow") {
          openWindow(id: "main")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Spacer()
        Button("Quit") {
          model.saveSettings()
          model.stop()
          NSApplication.shared.terminate(nil)
        }
      }.buttonStyle(.borderless).font(.caption)
    }
    .padding(14)
    // A compact MenuBarExtra size proposal can collapse a flexible ScrollView
    // when only a maximum is specified, leaving only Open/Quit.
    .frame(width: 380, height: panelHeight)
  }

  // Keep a real height so flexible content cannot collapse. Leave room for
  // native menu positioning on smaller displays; details scroll independently.
  private var panelHeight: CGFloat {
    min(700, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
  }
}

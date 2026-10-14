import AppKit
import SwiftUI

struct MenuBarStatusIcon: View {
  let model: AppModel

  var body: some View {
    let established = model.running && model.update.pipelineEnabledApplied != nil
    Image(systemName: established ? (model.update.pipelineEnabledApplied == true ? "video.fill" : "arrow.right.square") : "video")
      .accessibilityLabel(!established ? "UltraStudio LUT feed is stopped or starting"
        : model.update.pipelineEnabledApplied == true ? "UltraStudio LUT processing is active" : "UltraStudio LUT complete bypass is active")
  }
}

// MenuBarExtra's native window supplies menu bar positioning, dismissal and
// material. Its renderer is independent of the main window's video layer.
struct MenuBarInterface: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            FeedStateLabel(model: model)
            Spacer()
            StartStopButton(model: model).controlSize(.small)
          }
          FeedPreview(model: model, compact: true).frame(height: 150)
          PipelineEnableControl(model: model)
          Toggle("Video preview", isOn: $model.previewEnabled)
            .toggleStyle(.switch).controlSize(.small)
          Divider()
          PipelineControls(model: model, compact: true)
          LUTControls(model: model, compact: true)
          DisclosureGroup("Feed details") {
            VStack(alignment: .leading, spacing: 10) {
              FeedMetadata(model: model)
              FeedDiagnostics(model: model, compact: true)
            }.padding(.top, 6)
          }.font(.caption)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      Divider()
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
      }.buttonStyle(.borderless).font(.callout)
    }
    .padding(16)
    .frame(width: 360)
    .frame(maxHeight: 640)
  }
}

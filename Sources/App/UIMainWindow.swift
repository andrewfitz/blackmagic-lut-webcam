import SwiftUI

/// Main window content: session sidebar, camera columns by layout, on-demand
/// inspector and the status bar. Every change goes through `context.send`.
struct UIMainWindowView: View {
  let context: UIContext
  @State private var width: CGFloat = 1320

  /// The sidebar hides itself on narrow windows so the pictures keep their size.
  private var sidebarShown: Bool { context.session.sidebarVisible && width >= 1100 }

  var body: some View {
    NavigationSplitView(columnVisibility: columnVisibility) {
      UISessionSidebarView(context: context)
        .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
    } detail: {
      detail
        .safeAreaInset(edge: .bottom, spacing: 0) {
          UIStatusBarView(context: context)
        }
    }
    .navigationTitle(context.presentation.title)
    .navigationSubtitle(context.presentation.subtitle)
    .inspector(isPresented: inspectorBinding) {
      UIInspectorView(context: context)
        .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
    }
    .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
      Button(confirmationButton, role: .destructive) { context.confirm() }
      Button("Cancel", role: .cancel) { context.cancelConfirmation() }
    } message: {
      Text(context.confirmation?.message ?? "")
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .frame(minWidth: 980, minHeight: 680)
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    let cameras = context.presentation.cameras
    if cameras.isEmpty {
      ContentUnavailableView {
        Label("No Cameras", systemImage: "video.slash")
      } description: {
        Text("Add a camera, then choose its UltraStudio input.")
      } actions: {
        Button("Add Camera") { context.send(.addCamera) }
          .disabled(!context.session.canEditTopology)
      }
    } else {
      switch context.presentation.layout {
      case .programView:
        UIProgramView(context: context)
      case .single:
        ScrollView {
          if let camera = context.presentation.selected ?? cameras.first {
            UICameraColumnView(camera: camera, context: context)
              .frame(maxWidth: 1100)
              .frame(maxWidth: .infinity)
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(12, for: .scrollContent)
      case .sideBySide, .fourUp:
        ScrollView {
          if cameras.count <= 2 && context.presentation.layout == .sideBySide {
            HStack(alignment: .top, spacing: 12) {
              ForEach(cameras) { camera in
                UICameraColumnView(camera: camera, context: context)
                  .frame(maxWidth: .infinity)
              }
            }
          } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
              ForEach(Array(stride(from: 0, to: cameras.count, by: 2)), id: \.self) { start in
                GridRow(alignment: .top) {
                  UICameraColumnView(camera: cameras[start], context: context)
                  if start + 1 < cameras.count {
                    UICameraColumnView(camera: cameras[start + 1], context: context)
                  } else {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                  }
                }
              }
            }
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(12, for: .scrollContent)
      }
    }
  }

  // MARK: Bindings

  private var columnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { sidebarShown ? .all : .detailOnly },
      set: { next in
        let wantsVisible = next != .detailOnly
        if wantsVisible != context.session.sidebarVisible { context.send(.toggleSidebar) }
      })
  }

  private var inspectorBinding: Binding<Bool> {
    Binding(
      get: { context.session.inspectorOpen },
      set: { if $0 != context.session.inspectorOpen { context.send(.toggleInspector) } })
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { context.confirmation != nil },
      set: { if !$0, context.confirmation != nil { context.cancelConfirmation() } })
  }

  private var confirmationTitle: String {
    switch context.confirmation?.action {
    case .stopCamera(let id): return "Stop \(context.camera(id)?.name ?? "Camera")?"
    case .stopAllCameras: return "Stop All Cameras?"
    default: return "Are you sure?"
    }
  }

  private var confirmationButton: String {
    switch context.confirmation?.action {
    case .stopCamera: return "Stop Camera"
    case .stopAllCameras: return "Stop All Cameras"
    default: return "Continue"
    }
  }
}

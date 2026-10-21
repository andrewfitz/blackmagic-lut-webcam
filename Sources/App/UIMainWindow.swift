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
    // 680 pt is the window minimum; the content sits below the ~52 pt toolbar.
    .frame(minWidth: 980, minHeight: 620)
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
      // With one camera every grid layout is the single layout.
      let layout: UILayout = cameras.count == 1 && context.presentation.layout != .programView ? .single : context.presentation.layout
      switch layout {
      case .programView:
        UIProgramView(context: context)
      case .single:
        if let camera = context.presentation.selected ?? cameras.first {
          // Size the picture so the picture and its strip fit the window height.
          GeometryReader { proxy in
            let stripHeight: CGFloat = camera.collapsed ? 56 : 230
            let fitted = (proxy.size.height - stripHeight - 24) * 16 / 9
            let width = max(420, min(proxy.size.width - 24, fitted))
            ScrollView {
              UICameraColumnView(camera: camera, context: context)
                .frame(width: width)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(12, for: .scrollContent)
          }
        }
      case .sideBySide, .fourUp:
        ScrollView {
          if cameras.count <= 2 && layout == .sideBySide {
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
        // Only an explicit change on a wide window is a user choice; auto-hiding is not.
        guard width >= 1100 else { return }
        context.send(.setSidebarVisible(next != .detailOnly))
      })
  }

  private var inspectorBinding: Binding<Bool> {
    Binding(
      get: { context.session.inspectorOpen },
      // Set, never toggle: SwiftUI may echo the current value back through the binding.
      set: { context.send(.setInspectorOpen($0)) })
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { context.confirmation != nil },
      // Dismissal (Escape, clicking away) clears the pending action after the buttons
      // have run, so the destructive button never loses its action to the dismissal.
      set: { presented in
        guard !presented else { return }
        let cancel = context.cancelConfirmation
        DispatchQueue.main.async { cancel() }
      })
  }

  private var confirmationTitle: String {
    switch context.confirmation?.action {
    case .stopCamera(let id): return "Stop \(context.camera(id)?.name ?? "Camera")?"
    case .stopAllCameras: return "Stop All Cameras?"
    case .removeCamera(let id): return "Remove \(context.camera(id)?.name ?? "Camera")?"
    case .resetAllSettings: return "Reset All Settings?"
    default: return "Are you sure?"
    }
  }

  private var confirmationButton: String {
    switch context.confirmation?.action {
    case .stopCamera: return "Stop Camera"
    case .stopAllCameras: return "Stop All Cameras"
    case .removeCamera: return "Remove Camera"
    case .resetAllSettings: return "Reset and Quit"
    default: return "Continue"
    }
  }
}

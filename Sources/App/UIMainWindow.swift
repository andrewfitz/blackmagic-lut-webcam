import SwiftUI

/// Main window content: session sidebar, camera columns by layout, on-demand
/// inspector and the status bar. Every change goes through `context.send`.
struct UIMainWindowView: View {
  let context: UIContext

  var body: some View {
    NavigationSplitView(columnVisibility: columnVisibility) {
      UISessionSidebarView(context: context)
        .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
    } detail: {
      detail
        .safeAreaInset(edge: .bottom, spacing: 0) {
          UIStatusBarView(context: context)
        }
        // With both side columns open on a narrow window the pictures get squeezed and the
        // inspector is pushed past the window edge, so close the column opened earlier.
        // (A minimum width here makes AppKit loop on the split view's size constraints.)
        .onGeometryChange(for: Bool.self) { $0.size.width < 480 } action: { squeezed in
          if squeezed { context.send(.makeRoomForPictures) }
        }
    }
    .navigationTitle(context.presentation.title)
    .navigationSubtitle(context.presentation.subtitle)
    .inspector(isPresented: inspectorBinding) {
      UIInspectorView(context: context)
        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
    }
    .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
      Button(confirmationButton, role: .destructive) { context.confirm() }
      Button("Cancel", role: .cancel) { context.cancelConfirmation() }
    } message: {
      Text(context.confirmation?.message ?? "")
    }
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
      switch context.presentation.layout {
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
    // Showing the sidebar is always the user's choice, whatever the window width.
    // The split view keeps the first binding it gets, so read the live state, not this view's copy.
    Binding(
      get: { context.current.session.sidebarVisible ? .all : .detailOnly },
      set: { context.send(.setSidebarVisible($0 != .detailOnly)) })
  }

  private var inspectorBinding: Binding<Bool> {
    Binding(
      get: { context.current.session.inspectorOpen },
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

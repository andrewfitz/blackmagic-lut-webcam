import SwiftUI

/// Ultracam Help (⌘?): a short guide and every keyboard shortcut.
struct UIHelpView: View {
  private let shortcuts: [(String, String)] = [
    ("⌘↩", "Start or stop the cameras"),
    ("⇧⌘B", "Processing for the selected camera (off = complete bypass)"),
    ("⇧⌘P", "Video preview"),
    ("⌘R", "Record or stop the selected camera"),
    ("⌥⌘R", "Record all or stop all recordings"),
    ("⌃1 – ⌃4", "Cut Program to a camera"),
    ("⌃⌥A", "Automatic switching"),
    ("⌘1 – ⌘4", "Select a camera"),
    ("⌥⌘1 – ⌥⌘4", "Layout: Single, Side by Side, Program View, Four Up"),
    ("⌃⌘S", "Show or hide the sidebar"),
    ("⌥⌘S", "Collapse or expand all strips"),
    ("⌥⌘K", "Scopes for the selected camera"),
    ("⌥⌘I", "Inspector"),
    ("⌃⌥F", "Freeze the selected picture"),
    ("⌃⌥C", "Clean view for the selected picture"),
    ("⌘O", "Load a LUT for the selected camera"),
    ("⌘0", "Main window"),
    ("⌘,", "Settings"),
  ]

  var body: some View {
    Form {
      Section("Getting started") {
        Text("1. Install the Ultracam camera from the sidebar or Settings › Camera, and approve it in System Settings.")
        Text("2. Choose each camera's UltraStudio input in its inspector (⌥⌘I), then Start Camera.")
        Text("3. In your meeting app, choose \"Ultracam · Camera 1\" (or \"Ultracam · Program\" in Program mode).")
        Text("4. To back up the meeting, choose a recording folder and press Record. Recordings are the camera original, without the LUT or effects.")
      }
      Section("Good to know") {
        Text("Clicking a picture selects that camera; it never cuts. Cut with the toolbar, a strip's Cut button or ⌃1–⌃4.")
        Text("Stopping a camera that is recording or on air asks first.")
        Text("Changing Downscale, Color, Frame rate or Processing renegotiates the camera format, so the meeting's video updates briefly. The LUT doesn't.")
      }
      Section("Keyboard shortcuts") {
        ForEach(shortcuts, id: \.0) { key, command in
          LabeledContent(command) { Text(key).font(.body.monospaced()).foregroundStyle(.secondary) }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
  }
}

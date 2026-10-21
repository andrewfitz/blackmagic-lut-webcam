# Forms and secondary windows: inspector, Settings, Diagnostics, Help

Lens prefix **F**. Evidence: real-app tours in
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-tour/latest-Light/`
and `latest-Dark/` (abbreviated `L/` and `D/` below). Settings captures are the
`11-settings-*-2.png` files (640 x 548 pt window); the Diagnostics and Help
windows are `12-diagnostics-2.png` and `13-help-2.png`. Every finding below was
checked in both modes; nothing in this lens differs between light and dark
apart from F2's stale values, which depend on the camera's history, not the mode.

Not captured, so these are judged from code only and marked as such: the
inspector at exactly 300 pt, the Diagnostics App and Program tabs, the
Recording pane below the fold (Automation, Crash Recovery), and the Switcher
pane's "Advanced cut decisions" disclosure.

---

## Inspector

### F1 · P2 · At the 980-pt window the inspector runs past the window edge
- **Where:** `L/07-main-minimum-size.png`, `D/07-main-minimum-size.png` (compare
  with `L/02-main-sidebar-inspector.png`); `Sources/App/UIMainWindow.swift:11`,
  `:20`, `:28`, `:37`.
- **What's wrong:** With the sidebar and the inspector both open at the minimum
  window width, the inspector's right side is cut off. The section cards lose
  their right edge and rounded corners, and the toggles, `Load…` and `Choose…`
  sit 7 pt from the window edge instead of 20 pt (about 13 pt of the column is
  outside the window). Nothing becomes unreachable, but every row looks clipped.
  In the capture the detail column is about 430 pt wide, so the
  `makeRoomForPictures` guard (< 480 pt) should have fired, but both columns
  stayed open.
- **Cause:** sidebar min 220 + detail squeeze threshold 480 + inspector min 300
  = 1000 pt, more than the 980-pt window minimum. The column minimums alone
  can't fit at minimum width.
- **Fix:** Make the minimums add up to no more than 980: for example
  `.navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)` and
  `.inspectorColumnWidth(min: 280, ideal: 320, max: 460)` (200 + 480 + 280 =
  960). Separately, find out why `makeRoomForPictures` didn't close a column
  in this capture. It may only run when the width changes, not when the
  inspector opens into an already narrow window. At 280–300 pt the tightest row
  is the Input picker ("UltraStudio Mini Recorder 12G"); I couldn't measure it
  because no capture shows 300 pt. Give that picker's label
  `.lineLimit(1).truncationMode(.middle)` so it shortens cleanly instead of
  pushing the chevron off the row.

### F2 · P2 · The recording folder row contradicts itself
- **Where:** `L/02-main-sidebar-inspector.png`, `L/08-live-inspector.png`,
  `L/07-main-minimum-size.png`; `Sources/App/UIInspector.swift:178–183`,
  `Sources/App/UIPresentation.swift:534`.
- **What's wrong:** The row reads "No recording folder" with "Default folder"
  under it. The user can't tell whether a folder is set. The subtitle is
  chosen only by `folderIsCustom`, so it says "Default folder" even when no
  default exists. When a custom folder is set, "Use Default Folder" appears as
  a separate, leading-aligned row under it instead of in the folder row.
- **Fix:** With no folder anywhere, use the label "No folder chosen" with
  subtitle "Choose a folder to record". With the default folder, use the path
  with subtitle "Default folder". With a custom folder, use the path with
  subtitle "This camera's folder". Put "Use Default" in the row's trailing
  `HStack` next to `Choose…`, or make `Choose…` a `Menu` with
  `Primary action: Choose…` and an item "Use Default Folder". Don't give it a
  row of its own.

### F3 · P3 · Repeated labels and value-as-label rows in the inspector
- **Where:** `L/02-main-sidebar-inspector.png`; `UIInspector.swift:69`, `:81`,
  `:117`, `:131`, `:156`.
- **What's wrong:**
  - The header subtitle repeats the input name ("UltraStudio Mini Recorder
    12G"), which the Input picker shows again on the next row.
  - The "Processing" section header sits directly above a "Processing" toggle.
  - The LUT row puts the value ("No LUT loaded", greyed out) in the label
    column, while the "Input gamut" row under it uses a normal label.
  - The disabled "1 LUT" checkbox gives its reason ("Load a .cube LUT…") only
    in a tooltip, while the `Load…` button is in the next section.
- **Fix:**
  - Show the signal text in the header subtitle (`signalText(snapshot)`, for
    example "No HDMI signal" or "2160p29.97 · 4:2:2") instead of the input
    name.
  - Rename the section header to "Effects" and keep the toggle labelled
    "Processing", which matches ⇧⌘B and the strip.
  - Use `LabeledContent("LUT") { name or "None" · Load… }` so the LUT row
    reads like "Input gamut" below it.
  - When `lutName == nil`, add "Load a LUT below to use effect 1." to the
    Processing footer.

---

## Settings

### F4 · P2 · Fixed window height: some panes have empty space, others scroll with content hidden
- **Where:** all `L/` and `D/` `11-settings-*-2.png`; `Sources/App/UISettings.swift:25–26`.
- **What's wrong:** `.frame(width: 640).frame(minHeight: 460)` gives every pane
  the same height (548 pt). General, Camera and Advanced end with 100–200 pt of
  blank space. Recording, Switcher and Monitor scroll with whole sections out
  of view: Monitor's "Reduce quality under load" row is cut in half at the
  bottom edge, and Recording's Automation and Crash Recovery sections can't be
  seen at all. Native Settings windows resize to fit each pane.
- **Fix:** Remove `minHeight: 460` and give each pane its own height, so the
  window resizes when you switch tabs. For example, add `.frame(height: 400)`
  on General, about 430 on Camera and Advanced, and 640 on Recording and
  Switcher (these two can still scroll), with
  `.scrollBounceBehavior(.basedOnSize)` on every `Form`. Monitor becomes short
  once F5 is done.

### F5 · P2 · The Monitor pane is all read-only text posing as settings
- **Where:** `L/11-settings-Monitor-2.png`, `D/11-settings-Monitor-2.png`;
  `UISettings.swift:536–552`. The same pattern appears in Recording at
  `:201–203` ("Fragmented QuickTime movies · Always on", below the fold, code
  only).
- **What's wrong:** All seven rows are `LabeledContent` with grey text on the
  right, which looks like settings. None of them can be changed. "Off · Sony
  S-Log3 · EL Zone" reads like a current value but lists options, and
  "Always on" reads like a switch that is missing. The footers repeat it all
  in long paragraphs.
- **Fix (presentation only, since the brief rules out new features):** Remove
  the value column. Use one `Section("Monitor Tools")` with three or four
  plain rows, each a `Label(text, systemImage:)` with no trailing value. For
  example "Each camera has its own scopes, zebra, false color and picture
  signal. Use the tool buttons under its picture." and "New cameras start
  with monitor tools off." Make the false-color and under-load explanations
  section footers. Delete the "False color · Off · Sony S-Log3 · EL Zone" and
  "Source declarations" rows. In Recording, change "Fragmented QuickTime
  movies · Always on" into the first sentence of the Crash Recovery footer
  ("Takes are always written as fragmented QuickTime movies.").

### F6 · P2 · Camera pane: "Remove Camera" means two different things, and the status row is not a control
- **Where:** `L/11-settings-Camera-2.png`, `D/11-settings-Camera-2.png`;
  `UISettings.swift:286–312`, `UIInspector.swift:43`.
- **What's wrong:**
  - In Settings, "Remove Camera" uninstalls the system extension. In the
    inspector, "Remove Camera…" deletes one of the user's cameras. Same words,
    different objects, and one of them is hard to undo.
  - The status row "Ultracam camera" puts a two-line explanation in its label
    and has nothing on the right.
  - The two buttons sit in a row of their own with no label.
  - The footer repeats the unavailable reason.
- **Fix:**
  - Rename the buttons "Install Extension…" and "Uninstall Extension…", and
    the header "Camera Extension" can stay.
  - Make one row: `LabeledContent { HStack { ProgressView?; Install…; Uninstall… } } label: { Text("Ultracam camera"); Text(short status) }`,
    where the short status is "Not installed", "Installed" or "Needs a signed
    build".
  - Move the long reason into the footer only, and drop the second footer
    sentence when the reason is already shown.

### F7 · P2 · Switcher: controls stay active when they don't apply, and the timeline uses red
- **Where:** `L/11-settings-Switcher-2.png`, `D/11-settings-Switcher-2.png`;
  `UISettings.swift:381`, `:384–402`, `:508–512`, `:524`.
- **What's wrong:**
  - With strategy "Manual", Director mode and all six Shot Timing sliders are
    still enabled, though they only affect "Natural talking head". Only
    "Fixed interval" is disabled, and its label isn't dimmed, so it doesn't
    look disabled either.
  - The timeline marks "max" in red. Red is reserved for ON AIR and recording
    (D8).
  - The timeline labels are a fixed 9 pt and don't follow Dynamic Type.
  - "max 30 s" runs past the row's trailing inset.
  - The gradient fills only up to the minimum, so it doesn't show the bands.
  - "Dynamic analysis (later)" doesn't use the agreed "Coming later" wording
    (compare `:192`).
- **Fix:**
  - Wrap Director mode and the Shot Timing and Advanced sections in
    `if model.switcherSettings.strategy == .naturalTalkingHead`. If they have
    to stay visible, use `.disabled(strategy != .naturalTalkingHead)` and a
    footer such as "Used by Natural talking head." Show the Fixed interval row
    only for `.fixedInterval`.
  - Use `.orange` or `.primary` for the max marker.
  - Use `.font(.caption2)` for the labels, and clamp each label inside
    `0…width` (align the last label `.trailing` at the end).
  - Change the option to "Dynamic analysis (Coming later)".

### F8 · P3 · Inline hints and buttons share rows that should be footers
- **Where:** `L/11-settings-Switcher-2.png` (below the fold); `UISettings.swift:415–419`
  (Restore Defaults), `:64–70` (Login Items approval, conditional, code only),
  `:293–305` (extension approval, conditional, code only), `:326–328`.
- **What's wrong:**
  - "Restore Defaults" shares a row with a caption about timeline sidecars.
  - The approval hints put a caption or orange paragraph and a button in one
    `HStack`, so the text wraps against the button.
  - The Output picker repeats "Change while all cameras are stopped…" as an
    extra caption row, even though the same text is already its tooltip.
- **Fix:**
  - Make the caption the section footer, and put "Restore Defaults" alone in
    a trailing `HStack { Spacer(); Button }` row, or in the Shot Timing
    section's footer as a trailing button.
  - For the approval states, use `LabeledContent { Button("Open System Settings…") } label: { Text("Needs approval"); Text(path) }`.
  - Move the Output caption into the section footer, replacing the static
    footer while the mode is locked.

---

## Diagnostics

### F9 · P2 · The section picker floats in an invisible 520-pt box above the form
- **Where:** `L/12-diagnostics-2.png`, `D/12-diagnostics-2.png`;
  `Sources/App/UIDiagnostics.swift:22–37`.
- **What's wrong:** `.frame(maxWidth: 520)` centers a two-segment picker in a
  520-pt box, so it sits about 190 pt from the left edge. It isn't
  left-aligned, isn't centered on the window, and doesn't line up with the
  form column. The custom bar with its own divider also looks unlike the
  title bar of a Mac window.
- **Fix:** Remove the `HStack` bar and `Divider`. Use
  `.toolbar { ToolbarItem(placement: .principal) { Picker(…).pickerStyle(.segmented).labelsHidden().fixedSize() }; ToolbarItem(placement: .primaryAction) { Button("Copy Diagnostics", systemImage: "doc.on.doc") { … } } }`.
  Show "Copied" briefly with `.contentTransition` or a 2 s reset. Right now it
  says "Copied" until the window closes.

### F10 · P2 · A stopped camera shows "Live diagnostics appear while it runs" and then old zeros
- **Where:** `L/12-diagnostics-2.png` (the camera was started earlier in the
  tour, then stopped): the note is followed by "Input · No signal",
  "Delivered · 0.00 fps", "Processing · 0.00 ms" and all-zero drops.
  `D/12-diagnostics-2.png` (never started) shows only the note. Code at
  `UIDiagnostics.swift:91–96`.
- **What's wrong:** The note says the values only appear while the camera
  runs, then shows a full page of them. Those values are stale and say
  "No signal" instead of "Stopped".
- **Fix:** Use `if running, let update` for the Capture, Drops by Stage,
  Embedded Audio and Messages sections. If the last run's drop totals should
  stay visible, keep only "Drops by Stage" and change the note to "This
  camera is stopped. Values below are from its last run." When nothing is
  running, use `ContentUnavailableView("Camera Stopped", systemImage: "video.slash", description: …)`
  above the Recording section, not a one-line grey row.

### F11 · P2 · Monitoring is a tiny caption2 disclosure of run-on sentences
- **Where:** `D/12-diagnostics-2.png` (">" "Monitoring diagnostics" in caption2);
  `UIDiagnostics.swift:143–146`,
  `Packages/MonitorTools/Sources/MonitorToolsUI/MonitorDiagnosticsView.swift:16–41`.
- **What's wrong:**
  - The section header "Monitoring" sits over a disclosure titled "Monitoring
    diagnostics", which repeats it.
  - The disclosure label and contents are `.caption2` and secondary, smaller
    than every other row in the window.
  - Opened, it shows one-line sentences that pack several values together
    ("Picture cap … Hz · source offers … fps · delivered … fps") instead of
    rows.
  - "This surface" always reads "—" because Ultracam passes a hard-coded
    `"—"`.
- **Fix:** In `UIDiagnostics.swift`, don't embed `MonitorDiagnosticsView`.
  Build rows with `UIDiagnosticsRow` from the `MonitorDiagnostics` snapshot
  fields ("Picture rate", "Scope rate", "Quality", "Frames offered · admitted
  · skipped", "Monitor memory", "GPU deadline"). Drop "This surface". The
  shared package view can stay as it is for other hosts.

---

## Help

### F12 · P3 · Shortcut keys are small and faint; numbered steps don't hang
- **Where:** `L/13-help-2.png`, `D/13-help-2.png`; `Sources/App/UIHelp.swift:29–32`, `:41`.
- **What's wrong:**
  - `.font(.body.monospaced())` draws the modifier glyphs (⌘ ⇧ ⌥ ↩) in SF Mono.
    They come out about half the height of the command text and in grey, so
    the column the user came for is the hardest to read.
  - The steps are numbered by hand ("1. …"), so a wrapped line starts under
    the number instead of under the text (step 2's "Start Camera." in the
    capture).
- **Fix:**
  - Use `Text(key).font(.body).foregroundStyle(.secondary)`; the system font
    draws key glyphs at full size, as menus do.
  - Number the steps with `Label { Text(step) } icon: { Image(systemName: "\(n).circle") }`
    or with `HStack(alignment: .firstTextBaseline) { Text("\(n).").monospacedDigit().frame(width: 18, alignment: .trailing); Text(step) }`.
  - Also write the cut shortcut range the same way in both places: `⌃1–⌃4`
    at `:35`, but `⌃1 – ⌃4` at `:11`.

---

## Wording and capitalization (all four surfaces)

### F13 · P3 · Mixed case and wording for the same things
- **Where:** `UIInspector.swift:99`, `:183`; `UISettings.swift:66`, `:162`,
  `:164`, `:295`, `:573`, `:579`; `UIHelp.swift:28,34,39`;
  `UIDiagnostics.swift:112,116,195`.
- **What's wrong:**
  - The inspector toggle "Video Preview" is in title case, while its
    neighbours ("Input gamut", "Start with camera apps") are in sentence case.
  - Section headers are title case in Settings and Diagnostics ("Per-Camera
    Folders", "Drops by Stage") but sentence case in Help ("Getting started",
    "Keyboard shortcuts").
  - One idea has three forms: "Use Default Folder" (inspector), "Use Default"
    (Settings button) and "Uses default" (Settings text).
  - Settings paths use "→" (`:66`, `:295`), while Help and menus use "›".
  - The Advanced buttons "Open" and "Copy" don't say what they act on, while
    Diagnostics says "Copy Diagnostics".
- **Fix:**
  - Change the label to "Video preview".
  - Use title case for Help's section headers ("Getting Started", "Good to
    Know", "Keyboard Shortcuts").
  - Use "Use Default Folder" for the button everywhere and "Default folder"
    for the status text.
  - Use "System Settings › General › Login Items" everywhere.
  - Rename the buttons "Open Diagnostics" and "Copy Diagnostics".

---

## Top 5

1. **F1:** At the 980-pt window, the inspector is about 13 pt past the window
   edge. The column minimums (220 + 480 + 300) can't fit in 980.
2. **F4:** The Settings window is one fixed height: some panes have blank
   space while Recording, Switcher and Monitor hide whole sections below the
   fold.
3. **F5:** The Monitor pane (and "Fragmented QuickTime movies") is read-only
   text styled as settings. Make it plain explanation with no value column.
4. **F9 + F10:** In Diagnostics, the picker floats in an invisible 520-pt box,
   and a stopped camera shows "appears while it runs" followed by stale zeros.
5. **F7:** In the Switcher pane, director and shot-timing controls stay active
   under Manual, and the timeline uses red (D8) with fixed 9-pt labels that
   overrun the row.

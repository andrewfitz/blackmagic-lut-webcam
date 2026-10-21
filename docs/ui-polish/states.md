# States, wording and interaction consistency (prefix S)

Lens: whether one state reads the same everywhere (toolbar, picture, strip,
sidebar, inspector, status bar, menus, menu bar item), whether controls
match what they can do, keyboard, and wording.

Evidence paths are shortened:
- `tour-L/` = `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-tour/latest-Light/`
- `tour-D/` = `.../ui-tour/latest-Dark/`
- `verify/` = `.../ui-verify/latest/png/`

Every finding below was checked against the code. Code paths are relative to
`Sources/App/`.

---

## P1: broken or misleading

### S1 (P1) Auto switching with the default "Manual" strategy turns on but never switches
- **Where:** `UIToolbar.swift:103-107` (Auto toggle), `UICommands.swift:132-142` (Automatic Switching, Strategy), `UISessionBridge.swift:297-307`, `UISessionSidebar.swift:81`, `UIPresentation.swift:598`; backend `Shared/SwitcherCoordinator.swift:205` (only `.fixedInterval` acts on `automatic`) and `AppSettingsStore.swift:170` (strategy defaults to `.manual`). Evidence: `verify/main-program-meeting-1320-light.png` (Auto button in the toolbar).
- **What's wrong:** Out of the box the strategy is Manual. Pressing **Auto** (toolbar, ⌃⌥A, or the menu bar row) turns the button on. The status bar then says "Camera 1 on air · Auto" and the sidebar says "Switching: Auto · Manual", but nothing ever cuts. Hold Current Shot is also enabled under Fixed interval, where it does nothing (`manualHold` only reaches the natural talking head director, `AutoSwitcherBridge.swift:79`).
- **Fix:** Have one rule in the presentation: `canAutoSwitch = outputMode == .program && strategy != .manual`.
  - Disable the Auto toggle, the menu item and the menu bar row when it's false, with `.help("Choose a switching strategy in Program › Strategy first.")`.
  - Or make `.setAutoSwitching(true)` with a Manual strategy pick `.fixedInterval`. Either way, "Auto · Manual" must never show.
  - Enable Hold Current Shot only when `strategy == .naturalTalkingHead`.

### S2 (P1) Confirmation alerts for Remove Camera and Reset All Settings have a "Stop Camera" button
- **Where:** `UISessionBridge.swift:226-232` with `confirmTitle` at `UISessionBridge.swift:367-372`. The same thing is copied in `UIMenuBar.swift:250-255`. Triggered from Camera › Remove… (`UICommands.swift:83`) and Settings › Advanced › Reset (`UISettings.swift:604`).
- **What's wrong:** When the main window isn't visible, the bridge falls back to an `NSAlert`. Its destructive button comes from `confirmTitle`, which returns "Stop Camera" for every action except Stop All. So "Reset all settings? … Ultracam quits" gets a red **Stop Camera** button. When the main window *is* visible but Settings is in front, the dialog attaches to the main window behind Settings, so it looks as if nothing happened.
- **Fix:**
  - Make `confirmTitle` exhaustive: `.removeCamera` → "Remove Camera", `.resetAllSettings` → "Reset and Quit", `.stopCamera` → "Stop Camera", `.stopAllCameras` → "Stop All Cameras". Delete the copy in `UIMenuBar` and call the bridge's.
  - Choose the presenter by `NSApp.keyWindow`, not by "a main window is visible", so the Settings window shows its own alert.
  - Remove the repeated question from the start of each message (`UIAction.swift:98,100,108`: "Remove Camera 1? …", "Reset all settings? …", "Stop all cameras? …"). The dialog title already asks it.

---

## P2: clearly wrong or inconsistent

### S3 (P2) A camera that failed to start is labelled "Stopped" everywhere except its picture
- **Where:** `UIPresentation.swift:451` (statusBadge), which feeds the strip header (`UICameraColumn.swift:499`), the inspector header (`UIInspector.swift:72`), the sidebar camera list (`UISessionSidebar.swift:46`) and the menu bar submenu (`UIMenuBar.swift:387`). Evidence: `verify/main-problems-1320-light.png` (Camera 2).
- **What's wrong:**
  - The picture says "Couldn't start Camera 2 / Couldn't start: the UltraStudio is in use by another app" with a **Retry** button. Right under it, the strip badge says a neutral "Stopped", the record row says "Not recording · Start the camera to record", and the header has a separate **Start Camera** button.
  - So one problem shows up as two states with two different buttons. "Couldn't start" is also said twice in the picture (title and detail).
- **Fix:**
  - In `statusBadge`, return `("Couldn't start", .warning)` when `automaticStartFailed && !running`, before the "Stopped" case.
  - Make the strip's start button run `.retryAutomaticStart` in that state, and label it "Retry".
  - In `startFailureDetail` (`UICameraColumn.swift:129-132`), remove a leading "Couldn't start: " from the backend status, or show only the reason.

### S4 (P2) "No signal" appears up to six times on one screen, in three wordings, and the strip's version is wrong for other states
- **Where:**
  - Picture "No HDMI signal" (`UICameraColumn.swift:96`)
  - Header badge "No signal" (`UIPresentation.swift:455`)
  - Strip "Waiting for HDMI · Record becomes available with a signal" (`UIPresentation.swift:477`)
  - Status bar "Camera 1: no signal" (`UIPresentation.swift:652`)
  - Inspector badge "No signal" next to Signal "No HDMI signal" (`UIInspector.swift:72,222`)
  - Menu bar banner and submenu subtitle (`UIMenuBar.swift:289,388`)
  - Evidence: `tour-L/08-live-started.png` and `tour-L/08-live-inspector.png` (one camera: four, then six times).
- **What's wrong:**
  - The same fact is repeated, and the wording changes each time.
  - `.waiting` (`UIPresentation.swift:433`) also covers Starting…, Unsupported format and Input disconnected, so the strip says "Waiting for HDMI" when HDMI is present but in the wrong format, or when the device is unplugged.
  - In the tour, the camera also has no recording folder, but the strip only names the signal. The user fixes the signal and still can't record.
- **Fix:**
  - Use one term, "No signal", for the picture title and the inspector Signal row. Keep "HDMI" in the picture's detail line, which says what to check.
  - Drop the separate "Waiting for HDMI" title. In `.waiting`, set `recordTitle = "Can't record yet"` and build `recordDetail` from what's actually missing: "Needs a supported signal", "Needs a recording folder", or both joined.
  - When the folder is missing, show the **Choose Folder…** action in `.waiting` too (`UICameraColumn.swift:669`).
  - Don't show the status bar warning for a plain no-signal camera when there is one camera and its picture is on screen. Keep it for the menu bar icon.

### S5 (P2) The output has five names, and "not in use" is shown four times on one screen
- **Where:**
  - Window subtitle and status bar "Virtual cameras not in use" (`UIPresentation.swift:581`)
  - Strip "Ultracam · Camera 1 · Not in use" (`UIPresentation.swift:512`)
  - Sidebar "Ultracam · Camera 1 / Not in use" (`UISessionSidebar.swift:90`)
  - Compact status bar "Not in use", which has no subject (`UIStatusBar.swift:109`)
  - Program "Ultracam · Program · not in use" (`UIPresentation.swift:577`)
  - Also "the Ultracam camera" (`UISessionSidebar.swift:333-334`), "camera extension" (`UIInspector.swift:60`) and "virtual camera" (`UISessionSidebar.swift:183`)
  - Evidence: `tour-L/08-live-started.png`, `tour-L/08-live-inspector.png` (status bar reads only "Not in use").
- **What's wrong:** The thing a meeting app picks is called a virtual camera, the Ultracam camera, the camera extension or the output, depending on where you look. The capitalisation of "in use" also changes between places. With one camera the window shows the same "not in use" in the subtitle, sidebar, strip and status bar.
- **Fix:**
  - Use the published device name ("Ultracam · Camera 1") for a single output. Use "Ultracam cameras" for the plural, and keep "camera extension" only in Settings › Advanced.
  - Use sentence case "In use / Not in use" everywhere: change `UIPresentation.swift:577,581`.
  - Make the compact status text "Camera 1 not in use" or "Output not in use".
  - Remove the output summary from the window subtitle (see S6).

### S6 (P2) The window subtitle repeats the status bar and contradicts it on paused takes
- **Where:** `UIPresentation.swift:618-621`. Evidence: `verify/main-four-up-1320-light.png`.
- **What's wrong:** The subtitle says "Ultracam · Camera 1 · in use · 3 recording". The status bar says "REC 2 · paused 1", and the toolbar says "Stop All (3)". The subtitle counts paused takes as recording. Elsewhere it is just a copy of the status bar's first two segments.
- **Fix:**
  - Count only `.recording` in the subtitle and add "· 1 paused", using the same wording as `recordingSummary`.
  - Better: drop `outputSummary` from the subtitle and show only what the status bar doesn't (for example the on-air camera in Program mode), or `nil` when idle.
  - The title words "Meeting", "Program", "Recording" and "Ultracam" also change with state. Keep the title "Ultracam" and let the subtitle carry the state.

### S7 (P2) The menu bar preview shows the selected camera, not the one in the meeting
- **Where:** `UIMenuBar.swift:493-500`.
- **What's wrong:** In Separate mode with two cameras, once any output is in use the card shows `presentation.selected`. If Camera 2 is in the meeting and Camera 1 is selected in the window, the menu bar shows a large Camera 1 with no ON AIR badge. This is the one place the user goes to check what the meeting sees.
- **Fix:** Pick `presentation.cameras.first { $0.tally == .onAir } ?? selected` for `cameraPicture`.

### S8 (P2) The menu bar caption repeats what the picture just said
- **Where:** `UIMenuBar.swift:508-529`, `537`. Evidence: `verify/menubar-preview-single-meeting-light.png` ("Ultracam · Camera 1" + ON AIR + REC 12:31 on the picture, then "Ultracam · Camera 1 · in use · Recording 1 of 1" below). Also `verify/menubar-preview-program-meeting-light.png` and `tour-L/10-menu-bar-extra.png` ("Camera stopped" in the placeholder, then "Camera stopped" as the caption).
- **What's wrong:** The caption adds nothing in any of the four states, and "Recording 1 of 1" reads like a progress counter. The waiting state uses three different phrasings in one card: "Waiting for a camera app", "Ultracam starts when a meeting app opens its camera", and "Automatic · idle · starts when a camera app opens Ultracam".
- **Fix:**
  - Delete the caption. If something must stay, show it only for the two-thumbnail layout, where nothing says "not in use": `Text("Not in use")`.
  - Use one waiting sentence: "Starts when a meeting app opens Ultracam."

### S9 (P2) Controls that are enabled but do nothing
- **Where and what:**
  - **Show Recordings in Finder** is enabled with no folder set, and `.revealRecordings` silently returns (`UISessionBridge.swift:338-341`). Seen in `UICommands.swift:110`, `UIMenuBar.swift:359`, `UIStatusBar.swift:278`, and in `tour-L/10-menu-bar-extra.png` and `09-menu-Record.png` while the sidebar says "No default folder".
  - View › **Freeze Camera 1 / Clean View / Show Scopes** are enabled while the camera is stopped (`UICommands.swift:184-192`, `tour-L/09-menu-View.png`). The picture hides these tools unless `tileState.showsPicture`.
  - View › **Collapse All Strips** is enabled in Four Up and Program View (`UICommands.swift:166`). The toolbar button is disabled there (`UIToolbar.swift:70`).
  - The strip's **effect chips** stay clickable with Processing off (`UICameraColumn.swift:719-725`, only dimmed). The inspector disables the same checkboxes (`UIInspector.swift:127`).
  - The toolbar and Camera › **Start All Cameras** are never disabled. The menu bar row is disabled when no camera can start (`UIMenuBar.swift:325`).
- **Fix:**
  - Add `.disabled(session.defaultFolderPath == nil && no camera folder)` with help "Choose a recording folder first."
  - Add `.disabled(!selected.tileState.showsPicture)` to the three View items.
  - Copy the toolbar's layout condition to the menu item.
  - Pass `enabled: chip.enabled && camera.processing` into `UIChipToggle`.
  - Use the menu bar's start condition (`camerasRunning || cameras.contains(\.canStart)`) for the toolbar and the menu.

### S10 (P2) Program menu items show as enabled when they can't apply
- **Where:** `UICommands.swift:137-153`. Evidence: `tour-L/09-menu-Program.png`.
- **What's wrong:** In Separate mode, Cut, Automatic Switching and Hold are greyed out, but **Strategy**, **Anchor** and **Emphasis** draw as enabled submenus: `.disabled` on a `Picker` inside `CommandMenu` doesn't grey the submenu title. Anchor and Emphasis only matter for the natural talking head strategy.
- **Fix:** Wrap each picker in `Menu("Strategy") { Picker(...).pickerStyle(.inline) }.disabled(...)` so the submenu title greys. Better, show Anchor and Emphasis only `if session.strategy == .naturalTalkingHead`.

### S11 (P2) Rename works three different ways
- **Where:**
  - Camera › "Rename Camera 1…" only opens the inspector (`UICommands.swift:62`).
  - The strip's ⋯ › Rename… shows an alert with no explanation (`UICameraColumn.swift:419-426`).
  - The inspector's alert explains that meeting apps see the new name after the extension restarts (`UIInspector.swift:51-61`).
  - Disabled reasons are written into the item title: "Rename… (stop all cameras first)" and "Remove Camera… (stop all cameras first)" (`UICameraColumn.swift:575,587`).
- **What's wrong:** The ellipsis on the menu item promises a name prompt, but it only opens a panel. One of the two prompts leaves out the explanation, which matters a lot in a meeting. Putting the reason in parentheses inside the title isn't a macOS convention.
- **Fix:**
  - Move the rename alert into one shared modifier, driven by `UIInterfaceState.renamingCameraID`, and have all three entry points set it.
  - Keep plain titles ("Rename…", "Remove Camera…") and put the reason in `.help(...)`, as the inspector already does.

### S12 (P2) A failed recording is red and says "Recording stopped", which reads like a normal stop
- **Where:** `UIPresentation.swift:475` (`.critical` tone), `UIPresentation.swift:644` (status bar "Camera 1: recording stopped"), `UICameraColumn.swift:431-437` (red strip border and background), `UICameraColumn.swift:834`. Evidence: `verify/strip-failed-light.png`, `verify/strip-failed-collapsed-light.png`.
- **What's wrong:** D8 keeps red for ON AIR and recording. Here a red tinted strip, red "Recording stopped" text and the red record button sit next to a red "On air" badge, so the strip looks like it's still recording. "Recording stopped" is also what anyone would call a take they ended themselves.
- **Fix:**
  - Use `.warning` (orange) for `.failed` in both `recordTone` and `stateTone`.
  - Change the wording to "Recording failed" in the strip, the collapsed strip and the status bar warning ("Camera 1: recording failed"). The detail line already gives the cause and what was saved.

---

## P3: polish

### S13 (P3) On air, Program and Next are written and colored differently in each place
- **Where:**
  - Picture "ON AIR" (`UIPresentation.swift:218`)
  - Strip badge "On air" (`UICameraColumn.swift:525`)
  - Menu bar submenu "On Air", from `.capitalized` (`UIMenuBar.swift:382`)
  - Status bar "Camera 1 on air" (`UIPresentation.swift:599`)
  - The cut button's pending state is "Next" in the badge and menu bar but "Cut pending" in the strip (`UIPresentation.swift:507`)
  - The PROGRAM badge is green in the sidebar (`UISessionSidebar.swift:49`) but outlined or neutral on the picture and strip
- **Fix:**
  - Keep all caps only on the picture tally. Everywhere else use sentence case from one helper `UITally.label` ("On air", "Program", "Next"); `.capitalized` gives "On Air".
  - Use "Next" for the pending output line.
  - Use `.neutral` for `.program` in the sidebar.

### S14 (P3) Keyboard shortcut problems
- **Where and what:**
  - Cuts use ⌃1–⌃4 (`UICommands.swift:128`, `UIMenuBar.swift:311`). These are the system shortcuts for Mission Control › Switch to Desktop N, which many multi-desktop users turn on, and then the cut silently does nothing.
  - The menu bar's single-camera **Record** row shows ⌥⌘R (`UIMenuBar.swift:350`). The Record menu and the toolbar help call the same action ⌘R, and the main menu's ⌥⌘R is "Record All".
  - Shortcuts are typed into labels instead of attached: "Cut to Camera 1 (⌃1)" (`UICameraColumn.swift:556`) and "Cut  ⌃2" (`UICameraColumn.swift:742`, visible in `verify/main-program-meeting-1320-light.png`).
  - Pause/Resume has no shortcut, and there is no "Resume All": once everything is paused, Pause All goes grey and each camera has to be resumed separately (`UICommands.swift:106-107`).
- **Fix:**
  - Keep ⌃1–⌃4 (they are documented in Help), but also offer plain 1–4 on the main window while the pictures have focus (`.onKeyPress`). Mention the Mission Control conflict in the Help shortcut list.
  - In the menu bar Record row, keep `key: "r"` and use `modifiers: all ? [.command, .option] : .command`.
  - Remove the shortcut text from the titles and add `.keyboardShortcut(...)` in the ⋯ menu. The strip button keeps "Cut" with help text.
  - Change "Pause All" to toggle into "Resume All" when every take is paused, and give Pause/Resume of the selected camera ⇧⌘R.

### S15 (P3) The Camera menu repeats itself with one camera
- **Where:** `UICommands.swift:46-86`, `UIToolbar.swift:27-29`. Evidence: `tour-L/09-menu-Camera.png`.
- **What's wrong:**
  - With one camera, the menu has "Start Camera 1" and "Start All Cameras ⌘↩" doing the same thing, plus a "Select Camera" section with one item. The toolbar calls this "Start Camera", but its tooltip says "Start every camera (⌘↩)".
  - "Show Inspector" here has no shortcut and never changes to "Hide". View has the real toggle ⌥⌘I.
- **Fix:**
  - Use `presentation.camerasControlTitle` for the ⌘↩ item.
  - Hide the per-camera Start/Stop and the Select section when `cameras.count == 1`, and make the toolbar tooltip match the count.
  - Remove "Show Inspector" from the Camera menu.

### S16 (P3) Toggle commands that never show their state, and naming that changes by place
- **Where and what:**
  - View › "Freeze Camera 1" and "Clean View" are plain buttons (`UICommands.swift:185-188`). The hover control and context menu switch between "Clean View" and "Show Overlays" (`UICameraColumn.swift:272,310`), but the menu never shows that Freeze or Clean View is on.
  - The picture's context menu always says "Hide Preview" (`UICameraColumn.swift:324`), even when the preview is already hidden.
  - ⌘0 is "Open Ultracam" in the menu bar (`UIMenuBar.swift:368`) and "Main Window" in the Window menu (`UICommands.swift:201`).
  - The inspector is "Open Inspector" in the menu bar submenu (`UIMenuBar.swift:442`) and "Show Inspector" everywhere else.
- **Fix:**
  - Make Freeze and Clean View `Toggle`s bound to the presenter state (`isFrozen` and the clean set).
  - Show the "Hide Preview" item only when `tileState != .previewHidden`, otherwise "Show Preview".
  - Use "Show Main Window" and "Show Inspector" consistently.

### S17 (P3) The menu bar dropdown's order and grouping
- **Where:** `UIMenuBar.swift:322-376`. Evidence: `tour-L/10-menu-bar-extra.png`.
- **What's wrong:**
  - Processing and Video Preview, both rarely used, sit above Record.
  - "Start with Camera Apps" is a camera setting, but it's listed under Recording.
  - A "Camera" section header sits above a single row named "Camera 1".
  - The CPU/GPU line comes after Quit, which should be last.
  - The camera row subtitle shows "Live" when the take failed or there is no folder (`UIMenuBar.swift:389`), which hides the problem.
- **Fix:**
  - Order the rows: (problem banner) → Start/Stop → Record/Stop Recording → Program cuts and Auto → Cameras submenus → Show Recordings in Finder → Open Ultracam, Settings…, then the stats line, then Quit.
  - Move "Start with Camera Apps" next to Start/Stop. Skip the section header when there's one camera.
  - Add `case .failed: "Recording failed"` and `case .noFolder: "No folder"` to the subtitle switch.

### S18 (P3) Wording problems: repeated sentences and developer language
- **Where and what:**
  - The sidebar banner shows the installer's "… Capture and preview still work." and then adds "Preview and recording still work." (`UISessionSidebar.swift:326`, with text from `ExtensionInstaller.swift:25-33`). This is visible in every `tour-L/0x` capture.
  - Help texts expose implementation details: "There is no background retry loop" (`UIInspector.swift:204`), "Automatic start tries once per camera session" (`UICameraColumn.swift:131,477,779`), and "Zero KB · —" while recording without a signal (`UIPresentation.swift:531`, `verify/strip-recordingNoSignal-light.png`).
  - The status bar says "Audio: 2 of 2" when everything is fine (`UIPresentation.swift:609`), and "Audio —" when no camera is live.
  - The inspector shows "No recording folder" with a "Default folder" subtitle under it (`UIInspector.swift:178-179`, `tour-L/08-live-inspector.png`).
- **Fix:**
  - Drop the extra sentence in the banner.
  - Use "Retry to try again." and "Try starting the camera again."
  - Show "— · —" until bytes arrive.
  - Write "Audio OK" when every live camera has audio, and hide the audio segment when none is live.
  - Hide the subtitle when `folderPath == nil`.

---

## Top 5

1. **S1** Auto switching does nothing with the default Manual strategy, yet the toolbar, status bar and sidebar all say "Auto".
2. **S2** Alerts for Remove Camera and Reset All Settings have a destructive button labelled "Stop Camera", and from Settings the dialog can open behind the window.
3. **S7** The menu bar preview can show the wrong camera (the selected one, not the one in the meeting).
4. **S4 / S3** One problem is shown in several places with different words and different buttons: "No signal" up to six times, and "Couldn't start" in the picture versus "Stopped" in the strip.
5. **S9** Several enabled controls do nothing: Show Recordings in Finder with no folder, View-menu monitor tools on a stopped camera, effect chips with Processing off, Collapse All Strips in Four Up.

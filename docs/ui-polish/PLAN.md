# UI polish round: fix plan

Four audit reports sit next to this file: `hierarchy.md` (H), `forms.md` (F),
`states.md` (S) and `native.md` (N). Read `BRIEF.md` for context. Fixes are
split by file so no two agents edit the same file at the same time.

## Decisions on the findings

- **Type scale:** adopt the table at the top of `hierarchy.md`. On macOS,
  `.caption`/`.caption2` are 10 pt; nothing a person needs to read in the
  main window is smaller than `.subheadline` (11 pt), except badges and chips
  (`.caption.weight(.semibold)`). Overlays on the picture use
  `.subheadline.weight(.semibold)` in 24 pt capsules.
- **Strip clock (H2):** `.title2.weight(.semibold).monospacedDigit()` with the
  short format ("12:31", "1:02:03") everywhere.
- **Window title and subtitle (S6, H8):** the title is always "Ultracam"; the
  subtitle carries only what the status bar doesn't (for example the on-air
  camera in Program mode), or nothing when idle.
- **Color (N1, N5, S12):** colored *text* only where it's large or bold
  enough; small status text stays primary/secondary with a colored symbol or
  dot. A failed recording is orange with a warning symbol, worded "Recording
  failed". Red is only ON AIR and recording.
- **Remove the purple "LATER" tag (N4, H9).** "Coming later" stays as the
  secondary subtitle.
- **⌃1–⌃4 stay (S14);** Help mentions the Mission Control clash. No plain
  1–4 keys. Add Resume All (Pause All becomes Resume All when every take is
  paused) and ⇧⌘R for Pause/Resume of the selected camera.
- **Settings › Camera** buttons become "Install Camera Extension…" and
  "Remove Camera Extension…" (F6) so they can't be confused with removing a
  camera.
- **Deferred:** plain 1–4 cut keys, sparklines, anything the brief lists as
  "Coming later".

## Shared API (use these exact names)

Agent D adds these; other agents use them even if they don't compile yet
while D is still working.

- `UIAction.beginRename(cameraID: String)` and `UIAction.endRename`.
- `UISessionSnapshot.renamingCameraID: String?` (from
  `UIInterfaceState.renamingCameraID`).
- `View.uiRenameAlert(_ context: UIContext)` in a new file
  `Sources/App/UIRenameAlert.swift`: the one rename alert, including the note
  that meeting apps list the new name after the camera extension restarts.
  Agent C applies it once in `UIMainWindow`; the strip's ⋯ menu (A), the
  inspector (B) and the Camera menu (D) only send `.beginRename`.
- `UISessionPresentation.canAutoSwitch: Bool` (Program mode and a strategy
  other than Manual) and `UISessionPresentation.canHoldShot: Bool` (natural
  talking head only).
- `UISessionPresentation.canStartAny: Bool` (`camerasRunning` or any camera
  `canStart`), for the toolbar and menus.
- `UITally.label: String?` (sentence case: "On air", "Program", "Next").
  `UITally.badge` stays all caps for the picture.

Don't rename or remove existing presentation properties; add new ones.

## Ownership

- **A, strip and picture:** `UICameraColumn.swift`, `UIStyle.swift`,
  `UIMonitorTools.swift`. Findings H1, H2 (view), H3, H7 (strip), H11, H12,
  H13, H14, N2, N3, N6 (small targets in these files), N8, N9, N10, N11,
  N13, S3 (strip button shows Retry when `automaticStartFailed && !running`),
  S9 (chips), S11 (send `.beginRename`; remove the strip's own alert), S12
  (strip tone), S14 (no shortcut text in titles), S16 (Hide/Show Preview).
- **B, forms and secondary windows:** `UIInspector.swift`, `UISettings.swift`,
  `UIDiagnostics.swift`, `UIHelp.swift`. All F findings except F1, plus
  S11 (inspector sends `.beginRename`; remove its own alert), S14 (Help:
  the ⌃1–⌃4 Mission Control note, ⇧⌘R, Resume All), S18 (inspector
  wording), F6 wording above.
- **C, window chrome:** `UIMainWindow.swift`, `UISessionSidebar.swift`,
  `UIStatusBar.swift`, `UIToolbar.swift`, `UIProgramView.swift`. Findings F1
  (sidebar min 200, inspector min 280), H4, H5, H6, H7 (sidebar), H8, H9,
  H10, N1 (status bar, sidebar), N4, N6 (toolbar grouping with
  `ToolbarSpacer`, guarded for macOS 26), N12, S1 (toolbar Auto uses
  `canAutoSwitch`), S9 (toolbar Start uses `canStartAny`), S18 (banner).
  Apply `.uiRenameAlert(context)` once in the main window.
- **D, states, wording and menus:** `UIPresentation.swift`, `UIAction.swift`,
  `UISessionBridge.swift`, `UICommands.swift`, `UIMenuBar.swift`, new
  `UIRenameAlert.swift`, `Tests/UIPresentationChecks.swift`. All S findings
  not listed above, H2 (short clock format in the presentation), N5, plus
  the shared API.

I (the coordinator) own `Tools/UIVerify/*`, `Sources/App/UISelfTest.swift`,
`scripts/*` and integration: building, running every test layer and the
real-app tour, and a second review pass.

## Rules for fix agents

- Edit only your files. Re-read a file before editing; another agent may
  have changed a file you read for reference.
- Don't run `scripts/build.sh`, `scripts/test.sh`, `scripts/ui-verify.sh`,
  `scripts/ui-tour.sh` or the app. You may run `bash scripts/ui-typecheck.sh`
  to check your work; errors in other agents' files, or from shared API that
  D hasn't added yet, are expected while everyone works: judge only your own.
- Match the surrounding code style and comment density. Keep accessibility
  labels that tests use unless the finding says to change them, and list
  every user-visible string you changed or removed in your final report so
  the coordinator can update the UI tests.
- When a finding turns out to be wrong or not worth it, skip it and say why.
- Final report: what you fixed (by ID), what you skipped and why, and the
  changed strings.

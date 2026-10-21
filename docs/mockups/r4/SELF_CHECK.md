# Round 4 self-check

I reviewed all 15 r4 pages, text and dark/light renders, against D1–D8 and the round-4 rules. Every
fix below is applied and both appearances are re-rendered (`png/<page>.png`, `png/<page>-light.png`).
Fixes marked builder are in `r4.js` / `r4.css` and reach every page.

| # | Page | Issue | Fix |
|---|---|---|---|
| 1 | program-view | Camera 2 showed a permanent **NEXT** ring, a "next · at speech gap" cut button and "Camera 2 is next…". The director exposes only a pending cut, so a planned next camera is fabricated (D8, audit L8-07). | NEXT removed. Camera 2 has no ring and a plain `⌃2` cut button. Hint now reads "Next auto cut: speech gap after 10 s". |
| 2 | program-view | The Program audio lane has no backing data yet. | Tagged NEW; label widened so it doesn't clip. |
| 3 | builder (r4.js) | Effect help said "Changes the format **Zoom** receives", naming a consumer app (D8). Used by strips and the inspector on every page. | "Changes the camera output format". |
| 4 | main-inspector, spec | Same "format Zoom receives" wording in the legend and spec. | Reworded to "camera output format". |
| 5 | diagnostics | Camera message read "choose Ultracam **in Zoom**". | "…in your meeting app". The same string comes from `CaptureController` (see Notes for build). |
| 6 | states | UI strings named Zoom: "Zoom receives black…", "Needed before Zoom can see it", "as the camera in Zoom". | "Your meeting app receives black…", "Needed before meeting apps can see it", "…in your meeting app". |
| 7 | builder (r4.js) | A paused take showed the plain red **Record** circle. Clicking it stops the take, so it read as the wrong action (standalone, four-up, states). | Paused uses the stop-square control with the "Stop Recording" tooltip. |
| 8 | builder (r4.js) | Strip state "Recording · no signal" still showed a green "● 2160p 59.94" status badge. | Orange "No signal" badge. |
| 9 | builder (r4.js) | Tile state `recnosignal` drew a live picture while claiming no signal. | It now draws the No-signal placeholder ("The take stays open; nothing is written until the signal returns.") and keeps the orange REC pill. |
| 10 | states | "Program shows black" card had the outlined **PROGRAM** badge with a red ON AIR ring, contradicting the tally rule. | ON AIR badge, since a client is still receiving black Program. Caption reworded without the app name. |
| 11 | states | Status bar "Error" row said "Archive is full" but still showed "Archive 5 h 40 m left". | "8TB 1 h 52 m left · Archive full". |
| 12 | states | The keep-awake / lid-close sheet isn't in the app but wasn't tagged. | Tagged NEW. |
| 13 | states | Hold card pill "Auto · holding 8.2 s" implied a hold countdown, which isn't exposed. | "Shot held · 8.2 s" (current shot length, which is known). |
| 14 | diagnostics | Encoded rate read "707 Mb/s · 29.97 → 59.94 fps" (confusing; recordings are the camera original). | "707 Mb/s · 59.94 fps (camera original)". |
| 15 | diagnostics, builder | 8TB gauge drawn at 74% in Diagnostics against 93% in Settings (595 GB free of 8 TB). Archive gauge at 38% didn't match 5 h 40 m at 354 Mb/s (≈ 900 GB free). | 8TB 93% everywhere; Archive 55% (2 TB drive) in the builder and in Diagnostics. |
| 16 | menubar | State (i) "Drive full" pill showed a **red** dot next to "Not recording". Red is reserved for ON AIR / REC. | Neutral grey square. |
| 17 | menubar | State (c) said "97 GB so far" but the takes are 64.2 GB + 11.2 GB. | "75.4 GB so far". |
| 18 | settings | Items not in the current app weren't tagged: Start-with-camera-apps default for new cameras, monitor defaults for new cameras, Forget Saved LUTs, Reset all settings. | Tagged NEW. |
| 19 | monitor-tools | "Monitor unavailable" was tagged NEW, but the current app already shows it (`MonitorWorkspaceView` "Monitor unavailable", presenter `isPresentationAdmitted`). | NEW removed. |
| 20 | main-expanded, main-collapsed | Callout 6 covered the status bar's "Archive 5 h 40 m left" text. | Moved to the empty gap before the resources segment. |
| 21 | single | Legend said the dropdown shows "what Zoom receives". | "what the camera publishes". |

## Checked and fine

- **Camera naming:** no "Feed" remains on any r4 page.
- **D1 cuts:** cuts appear only in the toolbar, strip, ⌃1–⌃4 and dropdown rows. Context menus have no Cut.
- **D2:** "Updating output…" is present and there's no format lock anywhere.
- **D3:** the Stop Camera confirmation and Stop All Cameras exist.
- **D4:** there's no orange ring; "Skipped by Auto" is a text badge.
- **D5:** ⋯ is a native menu, and the inspector is on demand (⌥⌘I).
- **D6:** NEW and design-only everywhere.
- **D7:** selection is a blue outer ring.
- **Shortcut table (app-menus, spec):** no duplicates; ⌘0 is only the main window, Zoom to Fit is ⌥⌘0, Diagnostics has no shortcut, and ⌥⌘K / ⌃⌥A carry conflict notes.
- **Timecode names:** Mac Clock / Record Start / No Timecode Track.
- **False color:** Off / Sony S-Log3 / EL Zone.
- **Time left:** 1 h 52 m (8TB) and 5 h 40 m (Archive) are consistent everywhere they appear.
- **Light mode:** contrast is acceptable on the pages checked (main-collapsed, main-expanded, menubar); picture overlays stay dark glass.

## Intentionally left

- **Remaining mentions of "Zoom":**
  - legend and caption text that explains a scenario (for example the states caption about the 10 s debounce ignoring Zoom's settings preview)
  - the app-menus Window menu item "Zoom", which is the macOS window command
  - "Zoom In / Out / to Fit", which is picture zoom
  
  None of these is a consumer-identity claim.
- **Cut reasons** (max shot, speech gap, emphasis) are kept in Recent Cuts and Diagnostics. The director's instructions carry `reason` and `forced` (`AutoSwitcherBridge`), so they're backed by data. The current `UICutRecord` has only `automatic`; see Notes for build.
- **NEW tags** mark features missing from the **pre-redesign** app. Several of them (time left per drive, recent takes, recent cuts, Saved state, Auto hold) are now being built in the foundation, but the tags are left as they are for traceability.
- **Time left on 8TB in Four Up** is 1 h 05 m. Two cameras record to 8TB there, so it's intentionally lower than the 1 h 52 m used elsewhere.

## Notes for build (outside docs/mockups, not changed here)

- **Help text:** `Sources/App/UIPresentation.swift` chip help still says "Changes the format Zoom receives", which breaks D8. Use "Changes the camera output format".
- **Paused record control:** `UIPresentation` sets `recordButtonActive` only for `.recording`. A paused take should also show the stop square (the button stops the take).
- **Camera message:** `CaptureController` says "Virtual camera connected — choose Ultracam in Zoom". Consider "…in your meeting app".
- **Cut reasons:** `UICutRecord` could carry the director's `reason` and `forced` so Recent Cuts can show them.

# Visual hierarchy, typography and spacing (prefix H)

Scope: the main window. That means the picture overlays, the channel strip (expanded and
collapsed), the session sidebar, the status bar and the toolbar.

Evidence paths are shortened:

- `tour-L/` = `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-tour/latest-Light/`
- `tour-D/` = `.../ui-tour/latest-Dark/`
- `verify/` = `.../ui-verify/latest/png/`
- `r4/` = `docs/mockups/r4/png/`

## Why the sizes feel random: root cause

On macOS the system text styles have fixed sizes (HIG, macOS table):

| Style | macOS size |
|---|---|
| `.title2` | 17 |
| `.title3` | 15 |
| `.headline` | 13 bold |
| `.body` | 13 |
| `.callout` | 12 |
| `.subheadline` | 11 |
| `.footnote` | 10 |
| `.caption` | 10 |
| `.caption2` | 10 |

The r4 spec's typography table (`docs/mockups/r4/spec.html` §4) pairs iOS-like sizes with style names: "Caption · 11 (.caption)", "Status bar · 11.5 (.caption)", "Callout · 12: Camera original · no LUT or effects", "Values · 12 .monospacedDigit()", "Elapsed · 20". The implementation followed the style names, so about 65 `.caption`/`.caption2` calls (roughly two-thirds of all `.font(` calls in these files) render at **10 pt** where the design meant 11–12 pt. On macOS `.caption` and `.caption2` are the same size, so code that uses both to make a hierarchy (for example size `.caption` over drops `.caption2`) shows no difference on screen.

The result is that the main window has two sizes: 13 pt (camera name, sidebar rows) and 10 pt (almost everything else). The sidebar, which only summarizes the session, uses larger text than the strip the user actually works in.

### Current inventory (`.font(` calls)

| File | What's used |
|---|---|
| UICameraColumn.swift | `.caption` ×23, `.caption.weight(.medium)` ×5, `.caption.monospacedDigit()` ×4, `.caption.weight(.semibold)` ×3, `.caption.weight(.semibold).monospacedDigit()` ×2, `.caption.weight(.bold).monospacedDigit()`, `.caption.monospacedDigit().weight(.medium)`, `.caption2` ×2, `.caption2.monospacedDigit()`, `.callout.weight(.semibold)` ×2, `.subheadline.weight(.semibold)`, `.headline`, `.system(.title3, design: .monospaced).weight(.semibold)`, `.system(size: 9/10/11/12/26)` ×6 |
| UISessionSidebar.swift | `.caption` ×13, `.caption.monospacedDigit()` ×2, `.callout` ×4, `.callout.weight(.semibold)` ×3, default `.body` (unstyled rows), `.system(size: 9, weight: .heavy)` |
| UIStatusBar.swift | `.caption` ×7, `.caption.monospacedDigit()` ×3, `.headline` ×5 (popover titles), `.subheadline.weight(.semibold)`, `.callout.weight(.medium)`, `.callout.monospacedDigit()` |
| UIStyle.swift | `.caption2.weight(.semibold)` (UIBadge), `.caption.weight(.bold)` (tally), `.caption`/`.caption2` `.weight(.semibold)` (chips), `.caption2.monospaced()` ×2, `.caption2.monospacedDigit()`, `.system(size: 8/9, weight: .bold)` |
| UIToolbar.swift | no explicit fonts (system toolbar). Good. |

### Proposed scale

Define these once in UIStyle.swift (for example as `extension Font { static let uiRow = Font.callout … }`) and replace every `.font(` in the five files with one of them. Only use `.system(size:)` for SF Symbol glyph sizing inside fixed frames, never for text.

| Name | SwiftUI style | macOS pt | Use |
|---|---|---|---|
| **Title** | `.headline` | 13 bold | Strip camera name, expanded **and** collapsed; popover titles |
| **Row** (sidebar) | `.body` | 13 | Sidebar row primary text (the List default). Includes the folder row, recent and interrupted takes, banner titles (`.body.weight(.semibold)`) |
| **Row** (strip) | `.callout` | 12 | Strip primary lines: record title (`.callout.weight(.semibold)`), saved file name, folder path, output line, "Updating output…", alert rows |
| **Value** | `.callout.monospacedDigit()` | 12 | Size · bitrate, drops, time left, drive time left, dB readout, shot timer |
| **Meta** | `.subheadline` + `.secondary` | 11 | Sidebar row subtitles, strip labels ("Audio", "Processing"), footnote, status bar segments and resource readout |
| **Badge** | `.caption.weight(.semibold)` | 10 | UIBadge, chips, L/R, "Own folder". This is the floor: nothing smaller, no `.caption2` |
| **Overlay** | `.subheadline.weight(.semibold)` in a 24 pt capsule | 11 | Picture name, number, tally (`.bold`), REC, timecode (`.monospacedDigit()`), Output/Fit menus |
| **Clock** | `.title2.weight(.semibold).monospacedDigit()` | 17 | Strip elapsed only (spec said 20 monospaced; `.title2` is the nearest system style, and SF Pro digits match the rest of the app) |
| **Placeholder** | `.title3.weight(.semibold)` / `.callout` | 15 / 12 | Title and detail inside a full-size picture (or use `ContentUnavailableView`) |

---

## Findings

### H1 · P2: The strip uses smaller text than the sidebar that summarizes it

- **Where:** `tour-L/01-main-sidebar.png`, `tour-L/08-live-started.png`, `verify/strip-recording-light.png`.
  - Sidebar rows at body 13: UISessionSidebar.swift:45, 106, 178, 215, 230.
  - Strip at 10–11 pt: UICameraColumn.swift:617 (record title `.subheadline`), 623 (detail `.caption`), 630, 632 (size, drops), 684, 687 (folder, time left), 728 ("Processing"), 753 (output line), 461 ("Audio").
- **What's wrong:** On one screen the sidebar's "Not recording" (13 pt) is visibly larger than the strip's "Not recording" (11 pt). The sidebar's "Ultracam · Camera 1 / Not in use" is also larger than the same line in the strip. The camera's own control surface ranks below its summary, and every line in the strip except the name is 10 pt, so nothing in the strip stands out.
- **Fix:** Apply the scale above to the strip.
  - Record title: `.callout.weight(.semibold)`.
  - Record detail, folder path, output line and "Updating output…": `.callout`.
  - Size, drops and time left: `.callout.monospacedDigit()`.
  - "Audio", "Processing" and the dB readout: `.subheadline` `.secondary`.
  - Chips stay at Badge size.

  The strip grows by about 6–8 pt, which H5 gives back.

### H2 · P2: The recording clock is a different font and format from every other clock

- **Where:** `verify/strip-recording-light.png`, `verify/main-single-meeting-1320-light.png`. Code: UICameraColumn.swift:620 (`.system(.title3, design: .monospaced)`), UIPresentation.swift:362–371 (`elapsed` gives "00:12:31", `shortElapsed` gives "12:31").
- **What's wrong:** The strip's clock is set in SF Mono, so it reads like code next to SF Pro text. It says "00:12:31" while the picture pill, collapsed strip, toolbar and status bar say "12:31". At 15 pt it's barely larger than the 13 pt camera name and toolbar label, so the most important number while recording doesn't stand out. The r4 mockup (`r4/main-expanded-light.png`) has a clearly dominant clock.
- **Fix:** Use `Text(camera.recordDetail).font(.title2.weight(.semibold).monospacedDigit())` and drop `design: .monospaced`. This deviates from spec §4 ("Elapsed · 20 semibold .monospaced"): `.title2` is the nearest system style, and SF Pro digits match the rest of the app. Build `recordDetail` with `UIFormat.shortElapsed` for recording and paused states (UIPresentation.swift:465–468) so every clock on screen reads the same.
- **Trade-off:** r4 likely chose the zero-padded form because `shortElapsed` gets wider at the hour ("12:31" becomes "1:02:47"). That's one reflow per take, which is acceptable with monospaced digits. If it isn't, keep the long form and use it in **all** places instead. `Tests/UIPresentationChecks.swift` probably asserts the long `recordDetail` string, so update that expectation with the change.

### H3 · P2: Picture overlay pills have four different heights and are top-aligned

- **Where:** `verify/main-program-meeting-1320-dark.png` and `verify/main-four-up-1320-light.png` (top-left "1 · Camera 1 · ON AIR"; bottom row next to Freeze/Fit). Code:
  - UICameraColumn.swift:162: number badge 20×20, rounded rect, radius 6.
  - UIStyle.swift:51: name pill 24.
  - UIStyle.swift:82: tally 22.
  - UICameraColumn.swift:182: active-tool chips 22.
  - UIMonitorTools.swift:54: tool bar 30.
  - UICameraColumn.swift:293: view controls 30.
  - UICameraColumn.swift:158 uses `HStack(alignment: .top)`; UICameraColumn.swift:193 uses `.bottom`.
- **What's wrong:** The number, name and ON AIR badge visibly step down in height and their text baselines don't line up. The number is a square while everything else is a capsule. All overlay text is 10 pt, so the camera's name gets no more weight than the "Output" menu.
- **Fix:** Use one overlay metric: 24 pt capsules, Overlay font (`.subheadline.weight(.semibold)`).
  - Number badge: `.frame(minWidth: 24, minHeight: 24)` in `Capsule()`.
  - `UITallyBadge`: `.frame(height: 24)`.
  - Active-tool chips: 24×24.
  - Tool bar and view-controls capsules: 28. Give `overlayButton` a frame height of 22 and the capsule a frame height of 28, then use `HStack(alignment: .center)` for both overlay rows.

### H4 · P2: The status bar is in its compact mode at the default window size

- **Where:** `verify/main-single-meeting-1320-light.png` and `verify/main-program-meeting-1320-dark.png`, where the first segment reads just "In use". Code: UIStatusBar.swift:16–17 (`compact = width < 1200`, `essentialOnly = width < 900`) and UIMainWindow.swift:14 (the bar is a `safeAreaInset` of the **detail** column).
- **What's wrong:** The thresholds were written for a full-width bar (spec: "Status bar 30 pt · full width"), but the bar sits in the detail column. With the sidebar open at the default 1320 pt window it's about 1084 pt wide, so it always shows the short text. "In use" with no subject is the first and most prominent word in the bar. All segments are also 10 pt (`.font(.caption)`, :72, :131), where the spec asked for 11.5.
- **Fix:**
  - Let the content decide. Wrap `segmentsRow(compact: false)` and `segmentsRow(compact: true)` in `ViewThatFits(in: .horizontal)` instead of comparing widths, and keep only `essentialOnly` as a width rule, at about 700.
  - Make the short output text say what is in use: "Camera in use" / "Not in use" (UIStatusBar.swift:109).
  - Segment and readout font: `.subheadline` (11 pt).

### H5 · P2: Single layout leaves a 50 pt empty band under one camera

- **Where:** `tour-L/01-main-sidebar.png` and `tour-L/08-live-started.png`. The strip ends about 64 pt above the status bar, and the picture is narrower than the window allows (about 90 pt margins left and right). Code: UIMainWindow.swift:61–63 (`stripHeight = camera.collapsed ? 56 : 230`).
- **What's wrong:** The strip actually renders at about 168 pt (the spec says about 190), but the fit math reserves 230 pt plus 24. It also doesn't count the 10 pt column spacing. So the picture is shrunk to leave about 52 pt of dead space, which is exactly the "empty area below a single camera". After H1 the strip grows a little, so a constant will drift again.
- **Fix:** Measure the strip instead of guessing. In `UICameraColumnView`, report the strip height with `.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }` (a `@State` in the single-layout branch, passed down or read through a preference). Then compute `fitted = (proxy.size.height - stripHeight - 10 - 24) * 16 / 9`.

### H6 · P2: Four-up overflows the window, so cameras 3 and 4 have no visible strip

- **Where:** `verify/main-four-up-1320-light.png`. The bottom pictures run under the status bar and their strips are off-screen. Compare `r4/four-up-light.png`, where all four pictures and strips fit with side margins. Code: UIMainWindow.swift:83–94 (the grid sizes pictures by column width only).
- **What's wrong:** At the default size the bottom row's identity, record state and record button are hidden. The user has to scroll a monitoring grid to see half the cameras.
- **Fix:** Use the same height fit as Single. Read `proxy.size.height` in a `GeometryReader` around the grid, compute `cellWidth = min((width - 12) / 2, ((height - 12) / 2 - collapsedStripHeight - 10) * 16 / 9)`, apply `.frame(width: cellWidth)` to each column, and center the grid horizontally.

### H7 · P2: Two neighboring "same level" elements use different sizes

- **Where:** `verify/strip-recording-collapsed-light.png` against `verify/strip-recording-light.png`, and `tour-L/01-main-sidebar.png`. Code: UICameraColumn.swift:497 (`.headline`) against :774 (`.callout.weight(.semibold)`); UISessionSidebar.swift:115 (folder row `.caption`) between :106 and :230 (body rows); :134 and :153 (recent and interrupted take titles `.callout`), :84 (Switching row `.callout`) against body rows elsewhere.
- **What's wrong:**
  - In the strip, the camera name shrinks from 13 to 12 pt when the strip collapses, so it jumps when toggled.
  - In the sidebar's Recording section, "No default folder" (10 pt) sits between 13 pt rows and looks like a footnote rather than a setting with a Choose… button.
  - Take titles and the Switching row are 12 pt while other rows are 13 pt.
- **Fix:**
  - Collapsed strip name: `.font(.headline)`.
  - Sidebar folder row: remove `.font(.caption)` so it uses Row size.
  - Recent and interrupted take titles and the `LabeledContent("Switching")` row: remove `.font(.callout)`. Every sidebar primary line is then `.body` and every subtitle is Meta.

### H8 · P2: The same state is said three or four times on one screen

- **Where:** `tour-L/01-main-sidebar.png`, `tour-L/08-live-started.png`, `verify/main-single-meeting-1320-light.png`.
- **What's wrong:**
  - With one stopped camera the window shows "not in use" four times: the window subtitle "Virtual cameras not in use" (UIPresentation.swift:581/620), the sidebar Output row (UISessionSidebar.swift:90–91), the strip output line (UIPresentation.swift:512) and the status bar segment (same `outputSummary`). The subtitle and the status bar share one string word for word.
  - There are three "Start Camera" buttons for one camera: toolbar (UIToolbar.swift:21), picture placeholder (UICameraColumn.swift:113) and strip header (UICameraColumn.swift:542).
  - While recording, the elapsed time appears four times in two formats (see H2).

  Competing copies of the same fact flatten the hierarchy: nothing is clearly where you look first.
- **Fix:**
  - Window subtitle: drop `outputSummary` from `subtitleParts` (UIPresentation.swift:620). The status bar's first segment says it. The r4 mockups (`r4/main-expanded-light.png`, `r4/single-light.png`) do put the output summary in the subtitle, so this goes against the mockup. Treat this bullet as a P3 suggestion. Use the subtitle only for what isn't on screen elsewhere, for example "2 cameras · 1 recording", or leave it empty when idle.
  - Placeholder "Start Camera" button: show it only when the strip below is collapsed (`if camera.collapsed`), because the expanded strip's header has the same button 10 pt below. Keep the explanatory text.
  - Optional: in Separate mode with one or two cameras, the sidebar Output rows repeat the strip lines exactly. Consider keeping only the rows' "In use" subtitle. The mockup repeats this too, so treat it as P3.

### H9 · P3: Sidebar "LATER" chip is off-scale, all caps, and repeats its own subtitle

- **Where:** `tour-L/01-main-sidebar.png` and `tour-D/01-main-sidebar.png` (Automation → Backup recording). Code: UISessionSidebar.swift:189–195.
- **What's wrong:** It's a 9 pt heavy purple all-caps chip right next to the subtitle "Coming later", so the row says the same thing twice. It's below the spec's 10 pt minimum, all caps isn't a macOS sidebar convention, and purple is the r4 "NEW (mockups only) … Never shipped" marker color from `spec.html` §2, not an app color.
- **Fix:** Delete lines 193–195, the `Text("LATER")` and its padding and background. The secondary text and "Coming later" subtitle already carry it, as the brief's convention says.
- **Other all-caps checked and kept:** ON AIR, PROGRAM, NEXT and REC on the picture (UIStyle.swift:76–96, UICameraColumn.swift:215) and "REC" in the status bar follow broadcast tally convention and r4 §3. The strip already uses sentence case ("On air"). LATER is the only all-caps label that breaks macOS convention.

### H10 · P3: The extension banner says "still work" twice, and its title is smaller than the rows below

- **Where:** `tour-L/01-main-sidebar.png` (top of sidebar). Code: ExtensionInstaller.swift:25–26 (the reason ends "Capture and preview still work.") and UISessionSidebar.swift:326 (adds "Preview and recording still work."). Title at :324, :333 and :341 uses `.callout.weight(.semibold)` (12 pt).
- **What's wrong:** Two near-identical reassurance sentences stack in the sidebar's most prominent block. The banner's title (12 pt) is smaller than ordinary rows like "Not recording" (13 pt), so the one thing that needs action ranks below routine status.
- **Fix:** Remove UISessionSidebar.swift:326, or strip the trailing sentence from the reason and keep line 326 as the single statement. Banner titles: `.body.weight(.semibold)`. Body lines: Meta.

### H11 · P3: The "Camera original" footnote is too faint and too small

- **Where:** `verify/strip-recording-light.png` and `verify/strip-saved-dark.png` (right end of the folder row). Code: UICameraColumn.swift:694 (`.caption2` + `.tertiary`).
- **What's wrong:** It's the one line that tells the user the recording differs from what the meeting sees, yet it's set two steps smaller and one level fainter than the spec's "Callout · 12". Tertiary label on the strip's tinted background is hard to read in light mode, and `ViewThatFits` drops it entirely on narrower strips.
- **Fix:** Use `.font(.subheadline).foregroundStyle(.secondary)` (Meta). When it doesn't fit, move it into the record button's `.help` text instead of losing it (UICameraColumn.swift:602, `recordButtonHelp`).

### H12 · P3: Effect chips are the loudest thing in the strip

- **Where:** `verify/strip-recording-light.png` and `verify/strip-saved-dark.png` (four filled blue blocks). Code: UIStyle.swift:139–143 (`.semibold`, accent fill at 0.2, 22 pt tall).
- **What's wrong:** Four saturated accent blocks outweigh "Recording", the clock and the camera name. Chips are settings that rarely change during a meeting, but they read as primary state. Accent is also the selection color (D7), so a strip full of blue looks selected.
- **Fix:** Spec §2 assigns accent to "checkmark chips", so keep accent and lower its intensity: Badge font with `.weight(.medium)`, the on fill at `Color.accentColor.opacity(0.12)`, accent only on the checkmark glyph (`Image(systemName: "checkmark").foregroundStyle(.tint)`) with primary text, and a height of 20 to match UIBadge's 18 more closely.

### H13 · P3: The picture placeholder is tiny inside a full-size picture

- **Where:** `tour-L/01-main-sidebar.png` and `tour-L/08-live-started.png`. "Camera stopped" and "No HDMI signal" are 12 pt and 10 pt in a picture about 970 pt wide. Code: UICameraColumn.swift:385–387.
- **What's wrong:** The only message in the largest area of the window is set smaller than the sidebar rows, so a "no signal" problem looks like a caption.
- **Fix:** Title `.title3.weight(.semibold)`, detail `.callout`, symbol `.font(.system(size: 32, weight: .light))`. Keep the current sizes when `compact` (menu bar preview). Alternatively use `ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(detail) } actions: { … }` inside the dark environment, which scales natively.

### H14 · P3: Strip rows start their text at three different left edges

- **Where:** `verify/strip-recording-light.png` (2× render). Record-row text starts at about 50 pt, folder and output text at about 31 pt, and the meter's "L" at about 64 pt. Code: UICameraColumn.swift:609 (28 pt record button, spacing 10), 682–684 (folder icon, spacing 6), 749–753 (output icon, spacing 5), 460–461 ("Audio" label width 42, spacing 8). The r4 mockup has the same misalignment.
- **What's wrong:** The strip reads as a stack of unrelated lines instead of a form. The eye can't run down one column to read the state, the path and the output.
- **Fix:** Give every row the same leading gutter.
  - Wrap each row's leading glyph in `.frame(width: 28)`: record button, folder icon, output icon, and an `Image(systemName: "waveform")` replacing the "Audio" text label.
  - Use `HStack(spacing: 8)` in every row, so all text starts at 36 pt.
  - The header chevron (24 pt) can take `.frame(width: 28)` too, so the camera name lines up with the column below.

---

## Top 5

1. **H1** Strip text is 10–11 pt while the sidebar is 13 pt, so the summary outranks the control surface. The root cause is that spec sizes 11 and 12 were mapped to `.caption`, which is 10 pt on macOS. Adopt the named scale in the table.
2. **H3** Picture overlays mix 20, 22, 24 and 30 pt pills, top- and bottom-aligned, so the name and tally row looks ragged. Use 24 pt capsules, the Overlay font and center alignment.
3. **H2** The recording clock uses SF Mono and "00:12:31" while every other clock says "12:31", and it's barely larger than the name. Use `.title2.semibold.monospacedDigit()` and `shortElapsed` everywhere.
4. **H5 + H6** Single layout reserves a hardcoded 230 pt strip, leaving a 50 pt empty band. Four-up doesn't fit height at all and hides cameras 3 and 4. Measure the strip and fit both layouts to height.
5. **H4 + H8** The status bar is always compact at the default size (bare "In use"), and the same "not in use" appears four times on screen. Use `ViewThatFits` for density, take `outputSummary` out of the window subtitle, and show the placeholder's Start Camera button only when the strip is collapsed.

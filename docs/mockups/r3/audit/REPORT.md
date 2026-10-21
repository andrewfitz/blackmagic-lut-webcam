# Round 3 UI/UX audit report

- **Scope:** the 13 round-3 pages in `docs/mockups/r3/`, checked against the inventory in
  `docs/UI_REDESIGN.md` and the current source.
- **Method:** 12 lens agents (`L1.json`–`L12.json`). Each self-checked its findings before writing.
  Code claims behind P0/P1 findings that came from only one or two lenses were then re-verified
  by hand against the source. All are marked `verified` in `findings.json`.
- **Totals:** 232 findings (15 P0, 97 P1, 92 P2, 27 P3), plus suspect verdicts and tables. Many
  overlap across lenses. Those duplicates are effectively cross-verified, and they are merged into
  the themes below.
- **Decision made by the user:** the user-facing noun is **Camera**.

## 1. Top themes, ranked

### P0-1 · Clicking a picture means cut, focus and select at once
Lenses: L1-01, L2-02, L3-01, L5-01, L6-12, L12-01.

The pages say a click on a feed picture cuts Program. The monitor sheet says the same click focuses
the tile, which is the target of ⌃⌥F/⌃⌥C and tool edits. The Feed menu and ⇧⌘B act on the
"selected" camera. Adjusting zebra on Camera 2 mid-meeting would cut Zoom to it. It also breaks
the macOS convention that a click selects.

**Fix:**
- A click selects and focuses only.
- Cuts come only from explicit cut controls: toolbar cut buttons, strip "Cut", ⌃1–⌃4, dropdown cut rows.
- In Program view, source tiles get a visible Cut button.
- VoiceOver gets a named "Cut to Camera 2" action, never the default action.

### P0-2 → P2 (by user decision D2) · Format-changing effects briefly renegotiate the Zoom feed
Lenses: L2-01, L12-03, L1-05, L1-06, L8-01, L8-22, L10-03, L2-11, L9-03.
Verified: `CameraSink.send` throws when a frame doesn't match the negotiated format, which
disconnects the camera.

- **Effects:** Downscale, Color, Frame rate and Processing (bypass) change the output format. LUT doesn't.
- **Program cuts:** cutting between cameras whose processed formats differ disconnects on every cut.
  The mockups' own setup does this (59.94 vs 29.97).
- **Lost state:** the current app's "Updating output…" / "Applying change…" state was dropped.

**Fix (after D2):** allow the change, with no prompt and no lock. Restore the "Updating output…" state.
Help text on Downscale, Color, Frame rate and Processing says they change the format Zoom receives.
- Program mode shows one Program format and flags cameras that don't match it, ideally with
  runtime work to normalize them.

### P0-3 · "Stop" is ambiguous, unguarded and does less than it says
Lenses: L2-03/04/05/07, L8-05, L1-03/04, L12-05, L3-06, L11-01/02, L4-06/07, L7-02/03, L10-S8.
Verified: `AppModel.stop()` stops only the selected camera, and stops its recording.

Four things go wrong:
- **Stop Feed ends a recording:** ⌘↩ and the dropdown's top row end that camera's recording and its
  Zoom output without warning.
- **Program-mode Stop is partial:** it stops one source while the label says "Stop Feeds".
- **Unlabelled Stop All:** the toolbar's most prominent control, "■ 12:31 · 2", is really Stop All
  with no verb.
- **Doubled controls:** strips have two stop-recording controls next to Pause.

**Fix:**
- Name by object: **Stop Camera** (capture and output), **Stop Recording**, **Stop All Recordings (2)**.
- The record button is the only control for a take.
- Confirm only when an action ends a recording or interrupts a camera that's in use.
- Decide Program Stop semantics (D3).

### P0-4 · The "selected camera" is invisible
Lenses: L2-06, L3-02, L12-02, L7-05.

⇧⌘B, ⌘R, ⌘O and the Feed menu target it, but channel strips make all cameras look like equals.
The spec calls ⌘1–4 "Focus", while the menus call it "Select".

**Fix:**
- Merge selection and focus into one visible "selected camera": an accent ring on the
  picture/strip, distinct from tally.
- Menu items name their target ("Bypass Camera 1").
- Strip controls are always scoped to their own camera.

### P0-5 · Recording integrity failures are invisible
Lenses: L10-01, L10-02, L2-12, L10-06, L9-19, L9-18, L2-16.
Verified: the recorder rejects no-signal frames while the take stays open.

**Fix:**
- **Signal loss:** "Recording · no signal 0:42" in orange on the strip, the picture and the menu bar
  icon, with gap markers.
- **Disk full:** a final state that says what was saved and whether Recover applies.
- **Device unplugged:** distinct from "no HDMI signal".
- **Sleep:** prevent sleep while live or recording, and warn when the lid closes.

### P1-6 · The per-camera model doesn't exist yet (feasibility)
Lenses: L3-03, L8-03, L8-04, L8-06. Verified: `AppModel.swift:881` drops updates from cameras that
aren't selected.

Strips show live stats, effects, LUT and Start/Stop for every camera. Today only the selected
camera has them. The design is right for the user's goals, but this is the largest piece of
implementation work, and it must come first.

### P1-7 · Information the app can't know
Lenses: L3-08, L9-21, L11-03/04, L8-07/08/09, L10-07, L8-02.

- **Consumer names:** "In use by Zoom" is impossible. The extension only counts consumers.
  Use "In use", or "In use by 2 apps".
- **Persistent NEXT and the hold countdown:** the director exposes only a pending cut.
  NEXT appears only while a cut is pending.
- **Speech lanes:** per-camera lanes are fabricated (the director hears one audio stream).
  Show a single audio lane.
- **ON AIR with no viewer:** use "PROGRAM" until a client connects.
- **Transcript assisted** is the default director mode, but there's no speech recognizer.
- **Mock data:** the formats and recording rates shown are wrong.

### P1-8 · Automation rules are undefined
Lenses: L1-07, L8-13, L9-20, L2-14, L3-09, L8-12. Verified: an active recording counts as demand.

- **After Zoom closes:** a backup take keeps the feed running forever.
- **Junk takes:** Zoom's settings preview would start them.
- **Lost takes:** an auto-stop could end a standalone take.
- **Scope:** the setting looks global but is per camera.

**Fix:** a written rule set.
- Start a backup only after N seconds of continuous use.
- Auto-stop only takes that automation started.
- Show "Meeting ended · still recording" with Stop / Keep.
- Make the setting per camera, with a summary in the sidebar.

### P1-9 · Missing states and lost features
Lenses: L1-02/08/09/10/11/12, L3-04, L10-04/05/08/09/10, L9-01/03/05, L12-08.

- **No Start/Stop Camera control in the live window.**
- **No post-take "Saved · file · Show in Finder" state.**
- **Lost from today's app:** Preview error + Retry; install pending / approval waiting; LUT
  loading; starting/connecting.
- **No home for automatic-mode status** in the window.
- **Record control:** idle, disabled, finishing and mixed states aren't drawn.
- **Program edge cases:** losing the source that's on air; no healthy source at all.
- **Auto override:** no "Hold" (`manualHold` already exists).
- **Topology lock:** Rename and Add look enabled while running, but the app blocks them.
- **Program setup guidance:** nothing tells the user to "Choose Ultracam · Program in Zoom".

### P1-10 · Red overload, color-only signals, contrast
Lenses: L4-01, L12-04, L6-01/02/03/05/06.

- **Red overload:** about 11 red marks on one screen.
- **Colour-only signals:** sidebar tally is a red or green dot only (1.68:1 brightness difference).
- **Contrast:** overlay text measures 3.2:1 (primary) and 2.0:1 (secondary) over bright video;
  off-chip text is 2.5:1.

**Fix:**
- Red only for the on-air ring and badge.
- REC = red dot + neutral text; the record toggle in a neutral style; errors in orange with a triangle.
- Text badges for on air / next in the sidebar.
- Overlay pills on an opaque-enough backing for ≥ 4.5:1.
- Chip state shown by shape or icon, not tint alone.

### P1-11 · Clutter and duplication
Lenses: L4-02/10, L3-05/07, L12-06, S5, S9, S10.

- **Overlays:** all four picture corners are filled at rest.
- **Repetition:** recording state appears up to seven times; Auto has three toggles; the sidebar
  repeats the strips.
- **Collapsing doesn't calm:** the freed space refills with scopes and a timeline.

**Fix:**
- At rest a picture shows only identity, tally and REC; everything else appears on hover or keyboard focus.
- One primary place per state, with defined echoes (see the L3 state map in `findings.json`).
- Auto lives in one control.
- Collapsed is a calm state (scopes off by default); "Focus" hides the sidebar.

### P1-12 · Platform fit
Lenses: L5-02/03/04/06, L6-07/08, L12-07.

- **⋯ popover too big:** it's about 850 pt with a destructive action. Make ⋯ a Menu, and put the
  deeper settings in an inspector that opens on demand and is closed by default (D5).
- **Hidden tool settings:** long-press isn't discoverable. Use split buttons (`Menu(primaryAction:)`).
- **Dropdown:** an NSMenu with a preview item is feasible. Live clickable thumbnails need a spike;
  cut rows are the fallback.
- **Menu bar dots:** coloured dots break the template-icon convention, and orange is the system's
  microphone indicator.
- **Hover-only controls** need a keyboard and VoiceOver path. Live controls must be ≥ 24 pt.

### P2 themes (details in `findings.json`)
- **Terminology:** Camera (decided). Stop names. ⌘0 assigned twice. "Source timecode" writes no
  timecode track (a current-app issue: rename it). Jargon outside Diagnostics.
- **Consistency:** builder vs hand-built drift. Time-left figures contradict each other. No fixed
  status bar order. One icon means three things.
- **Responsive and environment:** minimum size, 13" displays, long names, full screen, and light
  mode are undesigned.

## 2. Decisions needed from the user

| # | Decision | Recommendation |
|---|---|---|
| D1 | Remove click-to-cut from pictures? Should dropdown thumbnails still cut? | Yes, remove it from pictures. In the dropdown, show tally on the thumbnails and put cuts in rows below them. |
| D2 | Format-changing effects while a camera app is connected | **Decided (user, 2026-10-21): allowed freely while Zoom is connected.** No confirmation and no lock setting. Keep the brief "Updating output…" state so the change stays visible. |
| D3 | Program-mode Stop | Stop Camera stops that camera only. Add "Stop All Cameras", and the model must match the label. |
| D4 | Orange "Skipped by Auto" ring | Drop the ring. Use a text badge only, so orange stays for warnings. |
| D5 | ⋯ popover vs an on-demand inspector for deeper camera settings | ⋯ as a Menu, plus an inspector that opens on demand (closed by default, so the view stays uncluttered). |
| D6 | Backup automation rules (debounce, which takes auto-stop) | Accept the P1-8 rule set. |
| D7 | Selection model | Merge selection and focus into one visible "selected camera". |
| D8 | NEW features to keep | Keep: time left per drive, recent takes, director timeline (single audio lane), Saved state. Drop or revise: consumer names. "Record with camera apps" only with the D6 rules. |

## 3. Round-4 change list (grouped by where it lands)

**Builders (`r3.js` / `r3.css`)**
- `tile()`:
  - rest state = identity + tally + REC only; hover/focus group for tools, signal and timecode
  - selection ring (accent), separate from tally
  - no click-to-cut copy
  - pill backing for contrast
- `strip()`:
  - one record control
  - Stop Camera in the header (or the ⋯ menu), with confirm when recording
  - labelled Processing switch with a format-change marker
  - "Updating output…" state
  - Saved state
  - recording-no-signal state
  - paused, no-signal and unsupported states built in (removes the hand-built copies)
- `toolbar()`: verb labels ("Record All" / "Stop All Recordings (2) · 12:31"), Stop All Cameras in
  Program mode, a collapse icon that isn't sliders.
- `sidebar()`:
  - drop the camera rows when there are 2 or fewer cameras (the strips already show them)
  - Auto only here or only in the toolbar, not both
  - per-camera automation summary
- `statusbar()`: fixed segment order, "In use" (no app names), drive-specific time left.
- Tally: red only for on air, "PROGRAM" when there's no client, NEXT only while a cut is pending,
  text badges everywhere.

**Pages**
- **main-expanded / main-collapsed:** apply the builder changes. Collapsed = calm (scopes off).
  Turn the ⋯ popover into a Menu plus an inspector variant (pending D5).
- **program-view:** a Cut button on the source tiles, a Program format line plus a mismatch warning,
  and a single audio lane in the timeline.
- **single, standalone, four-up:** builder changes; fix the mock formats and rates.
- **menubar:** cut rows instead of clickable thumbnails (pending D1), "In use" wording, row budget
  ≤ ~14, signal-loss and disk-full states, template icon plus a badge instead of coloured dots.
- **app-menus / spec:** Camera terminology, fix ⌘0, ⌘1–4 = "Select Camera", Stop names,
  "Source timecode" → "No Timecode Track".
- **monitor-tools:** split-button tool controls.
- **states:** add recording+no-signal, disk full, device unplugged, sleep/lid, approval pending,
  updating output, Saved, Program source lost / no healthy source, Auto hold, topology locked.
- **settings:** automation rules (D6) and honest wording for director mode. (No format lock, per D2.)
- **New page:** responsive sheet (980×680, 13" default, long names, full screen) and a light-mode pass.

**Runtime and model work the design depends on (for the implementation plan)**
- Per-camera runtime state and controls (P1-6).
- Program format normalization or mismatch detection (P0-2).
- A Stop All Cameras API.
- Recording-gap telemetry (P0-5).
- Sleep assertions.
- Automation rules (P1-8).
- A consumer count instead of a boolean.

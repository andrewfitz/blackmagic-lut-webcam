# Round 3 UI/UX audit plan

What is audited: the 13 round-3 pages in `docs/mockups/r3/` (HTML + PNG), checked against the
inventory in `docs/UI_REDESIGN.md`, the current source (`Sources/App`, `Sources/Recording`,
`Packages/MonitorTools`) and the user's goals.

**User goals (the yardstick for every finding)**
- The main job is video conferencing: Ultracam is the camera in Zoom.
- Recording serves two purposes: a backup of the meeting feed, or standalone recording with no virtual camera.
- Usually 1 camera, sometimes 2, at most 4.
- The user wants to see and monitor both cameras side by side.
- Recording and output are controlled per feed, independently.
- Native macOS 27 controls and style wherever possible.
- Less clutter (that's why strips collapse).

## 1. Method

1. **Review in parallel, one lens per agent (§3).** Each agent reads the PNGs and the HTML. When a
   finding depends on what the app can actually do, the agent also reads the inventory and the code.
2. **Every finding uses the schema in §4.** Without evidence (page + element, plus a code reference
   where relevant), it isn't a finding.
3. **Adversarial verification.** A second agent per lens tries to refute each finding: Is it really
   on the page? Does the code contradict it? Is the severity inflated? Is it a duplicate?
4. **Synthesis.** Merge duplicates across lenses, rank them, and turn them into a round-4 change list
   that names the pages and builders each change affects. Conflicts between lenses (for example
   accessibility vs density) go to the user as decisions, not silent picks.

## 2. Already suspected (agents must confirm or refute these, and look beyond them)

| # | Suspect | Why it matters |
|---|---|---|
| S1 | **Click on a picture means three things:** cut (Program), focus a tile (monitor shortcuts), select a feed (Feed menu, ⇧⌘B). | An accidental cut is visible in the meeting. This is the highest live risk. |
| S2 | **The "selected feed" is invisible.** ⇧⌘B, the Feed menu and ⌘1–4 act on the selected feed, but channel strips make all feeds look equal. | Bypass can hit the wrong camera mid-meeting. |
| S3 | **Changing effects mid-meeting interrupts the output.** The README says the producer drains and renegotiates the format when effects change. Toggling Downscale or Color while Zoom is live may blank or glitch the call, and the UI doesn't warn. | Live safety. |
| S4 | **Red is overloaded:** on air, REC, the record/stop button, errors, "ON AIR · Zoom" vs "ON AIR · Program". | Status can't be read at a glance. |
| S5 | **Recording state appears 5–6 times:** sidebar, strip, picture pill, toolbar button, status bar, menu bar icon. | Noise versus reassurance; decide which is primary and which are echoes. |
| S6 | **Stop is ambiguous:** toolbar "Stop" (feed), strip "Stop" (recording), "Stop Feed", the record button turning into stop, the toolbar "12:31 · 2" button (Stop All?). | Stopping the wrong thing. |
| S7 | **Start/Stop semantics differ by mode:** Separate stops the selected feed, Program starts or stops all sources. | Surprise behavior. |
| S8 | **Destructive actions without protection:** Stop recording, Stop All and Stop Feed are one click and sit next to Pause. | A take ended by mistake can't be undone. |
| S9 | **The picture's always-visible tool buttons** (5 tools) crowd 524 px pictures. | Clutter, the user's stated pain point. |
| S10 | **Sidebar cameras list duplicates the strips** with 1–2 cameras. | Wasted space, the user's earlier complaint. |
| S11 | **Unmarked inventions:** agents added items not tagged NEW (⌘= zoom, Copy Timecode, Swap Pictures, Input settings…, Show Live Preview, per-take quit progress, the orange "Skipped by Auto" tally). | Honesty and scope creep. |
| S12 | **Code drift:** false color changed during the session; other inventory sections may be stale. | Designs built on stale facts. |
| S13 | **Responsive rules are undefined:** at the 980×680 minimum, with long feed names, or on a 13" display. | Layout breakage. |
| S14 | **The menu bar dropdown is long** (20+ rows plus preview), which can exceed the screen height on small displays. | Unusable on laptops. |
| S15 | **Builder and hand-built variants drift** (paused and no-signal strips were hand-built on several pages). | Inconsistent states. |

## 3. Review lenses (one agent each)

### L1 · Task flows (cognitive walkthrough)
Walk each task step by step through the pages. Count clicks and decisions, and note dead ends,
hidden steps, and places where the user can't tell what happened.
- **T1** First launch → camera installed and approved in System Settings → input chosen → first Zoom call.
- **T2** Daily meeting with automatic start and backup recording: before, during, after.
- **T3** Turn the LUT on or off mid-meeting and check what Zoom gets.
- **T4** Two-camera Program meeting: manual cuts, then Auto, then overriding Auto.
- **T5** Standalone two-camera recording: arm, record, pause one, stop all, find the files.
- **T6** Something goes wrong mid-take (drive nearly full, HDMI pulled, Zoom grabs and releases the camera), then recovery.
- **T7** After a crash: recover interrupted takes.
- **T8** Change one camera's folder, or rename a camera, without touching the other.
- **T9** Use only the menu bar dropdown for a whole meeting.

For each task, look for:
- steps that require knowing something the UI doesn't show
- confirmation missing exactly when it matters
- feedback latency (queued vs applied cut, first fragment written)

### L2 · Live safety and error prevention
In a live meeting, which actions can hurt? Accidental cut, wrong-feed bypass, effect toggles that
renegotiate format, Stop vs Pause adjacency, quitting, closing the window, sleep or lid close,
changing the input while running.
- Is each disruptive action labeled, guarded (confirm, hold, undo) or deferred?
- Are hit targets ≥ 24 pt for live controls?
- Are keyboard shortcuts ones you can press by accident (⌃1 vs ⌘1)?
- Is there a "safe" state while presenting?

### L3 · Information architecture and the state model
- Map every piece of state (running, live, recording, paused, on air, next, consumer, bypass,
  automatic, disk, drops) to every place it appears. Flag duplicates without a role, and missing
  primaries.
- Is the selected-feed concept needed? If so, where is it shown?
- Do sidebar, strips, toolbar and status bar have clear, non-overlapping jobs?
- Do the deeper settings in ⋯ belong there, or should some be inline or in Settings?
- Is anything everyday buried, or anything rare promoted?

### L4 · Visual hierarchy, density and clutter
Work from the PNGs.
- What draws the eye first on each page? Is that right for a live operator?
- Overlay crowding on 524 px pictures; red overload; badge noise (including NEW tags).
- Scanning of strips; expanded vs collapsed value; empty or wasted regions; alignment and rhythm.
- Glass over video: legibility and glass-on-glass.

Propose simplifications: hover-only overlays, a single status chip, progressive disclosure.

### L5 · macOS 27 platform conformance
Check against the HIG and the installed `MacOSX27.0.sdk` (see `docs/UI_REDESIGN.md` §8):
- sidebar/toolbar/inspector norms, toolbar item grouping, Liquid Glass usage
  (controls layer, not content)
- popovers vs sheets vs inspectors for settings
- Settings window structure
- menu naming (title case, ellipsis rule, standard menus and shortcuts)
- MenuBarExtra size and behavior norms
- destructive button styling and placement
- tabs picker usage (macOS 27)
- full-screen and window resize behavior

Flag anything that can't be built with native controls, and say what custom work it needs.

### L6 · Accessibility
- Measure contrast for secondary and tertiary text on glass and on video
  (WCAG AA 4.5:1 text, 3:1 UI).
- Color-only signals: tally, meters, chips.
- VoiceOver labels, values and reading order for pictures, strips and meters.
- Full keyboard path to every action (overlays included).
- Reduce Transparency, Increase Contrast, Reduce Motion.
- Target sizes; Dynamic Type equivalents (text size settings).
- Light appearance beyond the single spec sample.

### L7 · Consistency and terminology
Diff the 13 pages against each other:
- the same state drawn differently (builder vs hand-built strips)
- the same thing named differently: Feed/Camera, Effects/Processing, Output/Processed Output,
  Stop/Stop Feed, Record All/Stop All, Program view/Multiview
- icon meanings, badge styles, shortcut labels, menu vs window wording

Output a terminology table, plus a list of state renderings to unify in the builders.

### L8 · Code truth and feasibility
- Map each visible element to a model property, runtime capability or explicit NEW proposal.
- Find unmarked inventions and stale facts (re-read the current code, not the inventory).
- Check each feature against current behavior: what records, how start/stop work per mode,
  output-mode lock, demand rules, LUT per feed, the 0.5 s black-frame behavior.
- Count simultaneous live pictures per page against the renderer/monitor-surface budget.
- List the `MonitorToolsUI` package API changes needed.

### L9 · Coverage and gaps vs the inventory
Check every row in `docs/UI_REDESIGN.md` §2–§5 against r3. Is it present, deliberately removed
(say where that's justified), or lost? Known risks to check:
- Hold Clean
- swap and expand tile; split ratio drag
- Retry preview; "Applying change…"
- Install pending state
- LUT title vs file name
- feed `enabled`
- Dynamic analysis (later)
- FeedNotice messages
- encoder details
- interval slider for Fixed interval

Also list missing scenarios: responsive/minimum size, long names, 13" display, external display
and full screen, light mode, sleep/wake, device hot-plug, extension approval pending, Zoom
switching cameras.

### L10 · States and failure matrix
Build a matrix of components × conditions and mark which cells are designed:
- **Components:** picture, strip, sidebar, toolbar, status bar, dropdown, menus
- **Conditions:** idle, starting, live, recording, paused, finishing, failed, no signal,
  unsupported, bypass, automatic waiting, failed start, disk low/full, extension
  missing/unsigned/pending, device unplugged, monitoring reduced, preview hidden, quit

Flag empty cells, and states whose transitions are unclear (what happens between them).

### L11 · Microcopy and content
- Are labels clear, short and consistent? Is the language plain (no jargon like "capture
  admission" in the everyday UI)?
- Honesty rule kept ("—", "No signal")?
- Helpful error text with one action?
- Truncation strategy for paths and names.
- Tone of confirmations.
- Help text carried over from the current app.

### L12 · Better approaches (divergent critic)
For the top 8 problems from the other lenses (or the suspects in §2 if run in parallel),
propose 2–3 alternative designs each, with tradeoffs and a recommendation. Examples:
- click-to-cut safety: double-click, cut bar only, or ⌥-click
- a selected-feed model vs feed-scoped commands only
- red overload: a separate REC glyph shape or color, ON AIR as a tally light
- strip density: progressive rows vs hover reveal
- the dropdown as a mini control surface vs a menu
- a "meeting mode" lock that hides disruptive controls while live

Must respect the user's decisions (session sidebar, collapsible strips, tally instead of a big
Program picture). Alternatives sit within those.

## 4. Finding schema

```json
{
  "id": "L2-03",
  "lens": "live-safety",
  "pages": ["main-expanded", "program-view"],
  "location": "picture click / tile focus",
  "issue": "One click on a feed picture both focuses the tile and cuts Program to it",
  "evidence": "main-expanded legend 2; monitor-tools focus ring; MonitorWorkspaceShell TapGesture focuses tile",
  "scenario": "Mid-meeting the user clicks Feed 2 to adjust zebra and Zoom cuts to Feed 2",
  "severity": "P0",
  "confidence": "high",
  "recommendation": "Cut only from cut controls / ⌃n; picture click focuses",
  "alternatives": ["double-click to cut", "⌥-click to cut"],
  "affects": ["r3.js tile()", "main-expanded", "program-view", "menubar", "spec §5"],
  "effort": "S"
}
```

**Severity:**
- **P0:** can disrupt a live meeting, lose or end a recording, or mislead about what's live/recorded.
- **P1:** frequent friction or confusion in core tasks T1–T5.
- **P2:** consistency or polish.
- **P3:** nice to have.

## 5. Deliverables

1. `docs/mockups/r3/audit/findings.json`: verified findings with verdicts.
2. `docs/mockups/r3/audit/REPORT.md`: top issues, a matrix per lens, the terminology table, the
   states matrix, the coverage table, and decisions needing the user.
3. A round-4 change list, grouped by builder/page, ready to apply.
4. Optional: annotated PNGs marking the top 20 findings.

## 6. Scale

12 review agents, ~12 verification agents (one per lens, batch-verifying that lens's findings),
and 1 synthesis agent: about 25 agents. L12 can run after the others for better input, or in
parallel against §2.

# Native macOS 27 fit, light/dark and accessibility (prefix N)

Evidence paths are abbreviated as follows:
`L/` = `ui-tour/latest-Light/`, `D/` = `ui-tour/latest-Dark/`, `V/` = `ui-verify/latest/png/`
(all under `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/`).
The offscreen renders (`V/`) appear to come from a window that isn't key: their toolbar and switches
draw in an inactive gray. To be safe, toolbar tint and switch color are judged from the real-app tours only.

What already fits the platform and needs no change: Settings (grouped `Form`, toolbar tabs), the
inspector (`Form` + `.formStyle(.grouped)`, checkboxes, `ContentUnavailableView`), the
confirmation dialogs, the window title and subtitle, the layout picker (segmented, icon-only, labelled),
the template menu bar icon with a knock-out badge, and the native `NSMenu` rows. The dark backing
under text drawn on video (`uiPictureOverlay`, `Color.black.opacity(0.72)`) is the right convention for
a video well. Leave it as it is.

There is **no Liquid Glass in the app's own views**. `UIGlassBackground` / `uiGlass(in:)`
(`UIStyle.swift:28-47`) is defined but never called, so there's no glass to misuse. It also means its
Reduce Transparency path is dead code, and nothing else in the UI reads `accessibilityReduceTransparency`
or `colorSchemeContrast` (N8).

---

### N1 · P2 · Colored *text* is unreadable in light mode
**Where:** `L/08-live-started.png` (orange "No signal" badge, orange "Camera 1: no signal" in the status
bar), `L/08-live-inspector.png` (Signal "No HDMI signal" in orange), `V/strip-ready-light.png` (green
"● 2160p 59.94" on a pale-green capsule, green "Ultracam · Camera 1 · In use"),
`V/strip-recordingNoSignal-light.png` (orange "Recording · no signal", green "0 dropped"),
`V/component-status-bar-light.png` (green "Ultracam · Program · in use"). The same captures in dark are fine.
Code: `UIStyle.swift:69-70` (UIBadge draws tone-colored text on a 0.16 tint of the same color),
`UICameraColumn.swift:618, 632, 755, 824-834`, `UIStatusBar.swift:73, 96-104`,
`UISessionSidebar.swift:213-216, 234`, `UIInspector.swift:91, 137, 211`, `UIProgramView.swift:240`.

**What's wrong:** systemGreen and systemOrange used as caption-size text on a white or near-white
background have a contrast of about 2.1–2.3:1, and systemRed about 3.5:1. All are below the 4.5:1 that
small text needs. In light mode the most important status words ("No signal", "In use", "Recording ·
no signal") are the hardest to read. macOS itself colors the symbol or a dot and leaves the words in a
label color.

**Fix:** put the tone on the glyph and keep the words in `.primary` or `.secondary`:
- `UIBadge`: `HStack(spacing: 4) { if tone != .neutral { Circle().fill(tone.color).frame(width: 6, height: 6) }; Text(text) }`,
  with `.foregroundStyle(.primary)` (`.secondary` for neutral) and a background of `.fill.tertiary`
  instead of `tone.color.opacity(0.16)`. That includes the strip's "On air" badge (a red dot still
  satisfies D8). White on red at `.caption2` is only about 3.6:1, so only the on-video `UITallyBadge`, which
  is larger and bold on a dark picture, stays filled.
- `UIProgramView.swift:240`: give the "Manual" cut badge a `.neutral` tone. Orange means a problem
  everywhere else, but here it only means "a person cut".
- Status bar `color(_:)`: apply the tone to the `Image` only and leave the `Text` `.primary`.
- Strip output line (`:755`), sidebar `UISidebarRow` (`:213-216`), `dropsLine` (`:632`), inspector Signal (`:91`):
  color only the symbol and keep the text `.secondary`. Where there's no symbol, add one
  (`exclamationmark.triangle.fill` in `.orange`, `checkmark.circle.fill` in `.green`).
- Collapsed state (`:824-834`): `Label(…, systemImage:)` with `.symbolRenderingMode(.multicolor)` or a
  colored icon and text in `.secondary`.

### N2 · P2 · The disabled record button reads as a pale-pink button, not as unavailable
**Where:** `L/01-main-sidebar.png` vs `D/01-main-sidebar.png` (pink in light, maroon in dark),
`L/05-main-collapsed.png` (22 pt version), `V/main-problems-1320-light.png` (Camera 2).
Code: `UIStyle.swift:109-121`.

**What's wrong:** when disabled, the red dot and the `Color.primary.opacity(0.75)` ring are simply faded
with `.opacity(0.35)`. Red at 35 % becomes pastel pink on white and brown-red on dark. It looks like a
styled state, not a disabled control, and it's the only pink in the app. Native disabled controls lose
their color.

**Fix:** remove `.opacity(enabled ? 1 : 0.35)`. Choose the colors from `enabled` instead:
the dot uses `enabled ? Color.red : Color.secondary.opacity(0.5)` (or `.quaternary`) and the ring uses
`enabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.4)`. Read `@Environment(\.isEnabled)`
so the look also follows a parent `.disabled`. `.disabled` already gives VoiceOver the "dimmed" state,
so no extra accessibility value is needed.

### N3 · P2 · Effect chips are hand-drawn toggles; a disabled chip almost disappears
**Where:** `L/01-main-sidebar.png` / `D/01-main-sidebar.png` (the "LUT" chip with no LUT loaded is barely
visible in both appearances), `V/main-problems-1320-light.png` (Camera 2 "LUT").
Code: `UIStyle.swift:128-152`; group dimming at `UICameraColumn.swift:725` and `:796`.

**What's wrong:** the chip is a plain button with a custom fill (`accentColor.opacity(0.2)`), a custom
stroke (`secondary.opacity(0.35)`) and its own disabled opacity of 0.45. The strip then multiplies that
by 0.5 when Processing is off, which leaves about 22 % opacity. Off chips have only a faint gray outline.
VoiceOver hears them as "selected/not selected" buttons (`.isSelected`) rather than toggles. They
don't follow the system's disabled, inactive-window or Increase Contrast rendering.

**Fix:** use the system toggle button:
`Toggle(isOn: binding) { if chip.isOn { Label(chip.title, systemImage: "checkmark") } else { Text(chip.title) } }`
`.toggleStyle(.button).buttonBorderShape(.capsule).controlSize(compact ? .mini : .small)`.
Remove the custom background, stroke and `.opacity`, and let `.disabled(!chip.enabled)` dim it.
For the Processing-off state, use `.disabled(!camera.processing)` on the chip group (matching the
inspector, `UIInspector.swift:127`) instead of `.opacity(0.5)` at `UICameraColumn.swift:725, 796`.
VoiceOver then reads it as a toggle with an on/off value, so `.accessibilityValue` and
`.accessibilityAddTraits(.isSelected)` can go.

### N4 · P2 · The purple "LATER" tag is off-palette and doesn't scale
**Where:** every sidebar capture, for example `L/01-main-sidebar.png`, `D/01-main-sidebar.png` (magenta on
dark gray). Code: `UISessionSidebar.swift:193-195`.

**What's wrong:** it's the only purple in the app, drawn as a custom 9 pt heavy rounded rectangle. It
carries no meaning that the "Coming later" caption right next to it doesn't already give. It pulls the eye
to a feature that doesn't exist yet. Because the font size is fixed, it doesn't follow the sidebar's
text size.

**Fix:** delete the `Text("LATER")…` block (lines 193-195) and the `Spacer` before it. The secondary row
plus "Coming later" says it. If a marker is wanted, use the system list badge, `.badge(Text("Later"))`,
on the row.

### N5 · P2 · Failed recording is drawn in red, the color reserved for on air and recording (D8)
**Where:** `V/strip-failed-collapsed-light.png` (red "Recording stopped" next to the red "On air"
badge, pink card with a red border), `V/strip-failed-light.png`. Code: `UICameraColumn.swift:434`
(`.failed → .critical`), `:440-445`, `:834`; `UITone.critical → .red` at `UIStyle.swift:12`.

**What's wrong:** a stopped or failed take uses the same red as a live recording and ON AIR. At a glance
the strip says "recording" when it has actually stopped recording. This breaks D8.

**Fix:** use `.warning` (orange) for `.failed` at `:434` and `:834`, with an
`exclamationmark.triangle.fill` symbol. Following N1, the words stay `.primary`. Keep `.critical` only
for recording and on air.

### N6 · P3 · Toolbar grouping is left to chance; the pending-cut outline doesn't match the toolbar shape
**Where:** `L/01-main-sidebar.png` (Start Camera, Record, collapse and inspector share one glass capsule),
`V/main-program-meeting-1320-light.png` and `V/main-standalone-1320-light.png` (the same items split into
separate capsules). Code: `UIToolbar.swift:20-80` (each item is a separate
`ToolbarItem(placement: .primaryAction)`), `UIToolbar.swift:122`.

**What's wrong:** macOS 26+ groups adjacent toolbar items into shared glass by itself, so the grouping
changes with the camera count and mixes the transport verbs (Start, Record) with view toggles (collapse,
inspector). First-party apps group by function and keep the inspector toggle on its own at the trailing
edge. In Program mode, the pending-cut outline hard-codes a `RoundedRectangle(cornerRadius: 6)` over a
toolbar button whose shape the system controls, so the radius can't follow the toolbar's button shape.

**Fix:** wrap Start/Stop cameras and the record control in one `ToolbarItemGroup(placement: .primaryAction)`,
then the layout picker and collapse in a second group, then the inspector toggle on its own. On
macOS 26+, put a `ToolbarSpacer(.fixed)` between the groups, guarded with `#available` like the other
macOS 26 APIs. Optionally use `systemImage: "sidebar.trailing"` (the variant that flips for right-to-left layouts)
for the inspector. In `UIToolbarCutGroup` (and `UIProgramView.swift:180`), drop the drawn outline and
show "pending" with the button itself: `.tint(.green)` on the `.bordered` button, or
`.buttonBorderShape(.capsule)` with a matching `Capsule().strokeBorder(.green, lineWidth: 1.5)`.

### N7 · P3 · Hit targets under 24 pt
**Where:** `V/main-program-meeting-1320-light.png` (monitor-tool bar, top of Camera 1),
`L/05-main-collapsed.png`, `L/01-main-sidebar.png` (⋯ menu).
Code: `UIMonitorTools.swift:85-91` (the settings chevron is **11 × 24 pt** with a 7 pt glyph),
`UICameraColumn.swift:805-806` (collapsed record button 22 pt), `UIStyle.swift:140` (compact chips 18 pt tall),
`UICameraColumn.swift:592-596` (`ellipsis.circle` borderless menu, about 17 pt).

**What's wrong:** these are frequent controls with small targets. The 11 pt chevron next to a 24 pt
toggle is easy to miss, and clicking it opens settings when the user meant to toggle the tool, or the
other way round.

**Fix:** make each monitor tool the system split button:
`Menu { settings… } label: { Image(systemName: tool.symbol) } primaryAction: { toggle() }` with
`.menuStyle(.button).buttonStyle(.borderless)`. It gets a correctly sized indicator and is one
accessibility element with a "show menu" action. For the ⋯ menu, use
`Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)` with `.frame(minWidth: 24, minHeight: 24)`
and `.contentShape(Rectangle())` on the label. Keep the collapsed record button at 24 pt.

### N8 · P3 · Custom fills and strokes ignore Increase Contrast; Reduce Transparency isn't handled anywhere
**Where:** `D/01-main-sidebar.png` (the channel-strip card is barely separated from the window
background when not selected), `L/01-main-sidebar.png`. Code: `UICameraColumn.swift:439-447`
(`Color.primary.opacity(0.045)`, border `.clear` when unselected), `UIStyle.swift:143, 172`,
`UIProgramView.swift:153, 248` (`.quaternary.opacity(0.5)`), `UIDiagnostics.swift:279`,
`UISettings.swift:507`, `UISessionSidebar.swift:279`.

**What's wrong:** the opacity values are tuned for standard contrast. With Increase Contrast on, the
system strengthens its own fills and separators but not these, so the strip card and the meter tracks
stay faint. The app's only Reduce Transparency handling sits in the unused `UIGlassBackground`.

**Fix:** use semantic styles. For the strip card, use `.background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))`,
or `Color(nsColor: .quaternarySystemFill)`, with `.strokeBorder(.separator)` when unselected. Use
`.fill.tertiary` for the meter and shot-timer tracks. Read
`@Environment(\.colorSchemeContrast)` in `UIChannelStripView` and set the border width to 1.5 when
`.increased`. Either adopt `uiGlass` (N11) or delete `UIGlassBackground` so it doesn't suggest that
Reduce Transparency is covered.

### N9 · P3 · Fixed point sizes don't follow the system text size
**Where:** `L/11-settings-Switcher-2.png` (9 pt "min 10 s / soft max 20 s / max 30 s"), all sidebar captures
(LATER), the picture overlays in `V/main-program-meeting-1320-light.png`.
Code: `UISettings.swift:524`, `UISessionSidebar.swift:193`, `UIStyle.swift:136`,
`UIMonitorTools.swift:73, 87`, `UICameraColumn.swift:181, 222, 230, 300, 513`.

**What's wrong:** `.font(.system(size:))` stays fixed when the user enlarges text (Accessibility ›
Display › Text Size, or the sidebar size), while the text-style text around it grows. The 9 pt
shot-timing labels and the 7 pt chevron are already the smallest text in the app.

**Fix:** use text styles. Replace 9 pt labels with `.caption2`. Size symbols that sit beside text with
`.imageScale(.small)` or the surrounding text style (`.font(.caption2.weight(.bold))` for the chip
checkmark, `.font(.caption)` for the overlay tool icons) instead of point sizes.

### N10 · P3 · The live status badge contains a literal "●" that VoiceOver reads aloud
**Where:** `V/strip-ready-light.png` ("● 2160p 59.94"). Code: `UIPresentation.swift:453`, echoed as
the accessibility label at `UIStyle.swift:71`, and in the sidebar camera rows (`UISessionSidebar.swift:46`).

**What's wrong:** VoiceOver says "black circle 2160p 59.94". The dot is decoration typed into the text.

**Fix:** make the badge text `format` only and draw the dot as `Circle()` in `UIBadge` for
`.positive` (this matches N1's dot-plus-label badge). The accessibility label then needs no change.

### N11 · P3 · Controls over the picture are flat black capsules, not system glass
**Where:** `V/main-program-meeting-1320-light.png` / `-dark.png` (monitor tool bar and Freeze/Clean/Fit/Detach
bar on Camera 1). Code: `UICameraColumn.swift:269-306`, `UIMonitorTools.swift:39-59`.

**What's wrong:** the hover controls for the picture are custom black 72 % capsules with white plain
buttons and a hand-drawn "on" highlight (`Color.white.opacity(0.24)`). On macOS 26+, the system video
controls (AVKit and QuickTime) are glass, and the app already has a guarded glass helper for this.
Static text labels over video (camera name, timecode, REC) should keep the dark backing for legibility.
This finding covers only the *interactive* bars.

**Fix:** wrap the two bars in a `GlassEffectContainer` and replace the black background with
`.uiGlass(in: Capsule())` (macOS 26 glass, material on 15, opaque with Reduce Transparency).
Keep `.environment(\.colorScheme, .dark)`. Show a tool's on state with
`.buttonStyle(.glass)` / `.glassProminent` on macOS 26 (or a `Toggle(.button)` per N3) instead of the
white overlay.

### N12 · P3 · The sidebar camera list and the Diagnostics header are hand-built where system containers exist
**Where:** Diagnostics: `L/12-diagnostics-2.png` (a segmented picker and Copy button in a custom bar under
the title bar, followed by a `Divider`). Sidebar rows (only with 3+ cameras, so no real-app capture; checked in
code only): `UISessionSidebar.swift:39-56`. Diagnostics: `UIDiagnostics.swift:22-37`.

**What's wrong:** the sidebar camera rows are `.plain` buttons with
`listRowBackground(accentColor.opacity(0.15))`. They don't get the system selection (accent fill with
white text, gray in an inactive window), arrow-key navigation, or the correct selected trait. The
Diagnostics window draws a second toolbar inside its content instead of using the window toolbar.

**Fix:** sidebar: `List(selection: Binding(get: { presentation.selected?.id }, set: { if let id = $0 { context.send(.select(cameraID: id)) } }))`.
Tag the camera rows with `.tag(camera.id)` and drop the `Button`, the `listRowBackground` and the manual
`.isSelected` trait. Other rows are untagged and so can't be selected. Diagnostics: move the
picker to `.toolbar { ToolbarItem(placement: .principal) { picker } ToolbarItem(placement: .primaryAction) { copy } }`
and remove the HStack, padding and `Divider`.

### N13 · P3 · The selected camera gets two blue outlines
**Where:** `L/01-main-sidebar.png`, `D/01-main-sidebar.png`, `L/05-main-collapsed.png` (blue ring around
the picture plus a blue border around its strip). Code: `UICameraColumn.swift:67-72` and `:418, 446`.

**What's wrong:** D7 sets the picture's ring as the single selection and focus indicator. The strip
adds a second accent outline (`accentColor.opacity(0.55)`), so one selection shows two blue rings.

**Fix:** at `:446`, return `.clear` (or `.separator` per N8) for selected strips. Keep the warning and
critical tone borders.

---

## Top 5

1. **N1**: colored status text (green "In use", orange "No signal", status bar) is about 2:1 contrast in
   light mode. Color the symbol or dot and keep the words in label colors.
2. **N2**: the disabled record button is pale pink or maroon because it's faded red. Draw it in gray when disabled.
3. **N3**: replace the custom effect chips with `Toggle(.button)` capsules. Disabled chips fade to about 22 %,
   and VoiceOver hears them as "selected" buttons.
4. **N5 + N4**: failed recording is red, which conflicts with D8. Remove the purple "LATER" tag.
5. **N6 + N7**: group the toolbar explicitly (transport | view | inspector, with `ToolbarSpacer`), and fix the
   targets under 24 pt (the 11 pt monitor-tool chevron should become a system split-button `Menu`).

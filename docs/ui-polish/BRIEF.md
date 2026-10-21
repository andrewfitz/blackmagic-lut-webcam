# UI polish round: audit brief

Ultracam is a native macOS app (SwiftUI, macOS 27 SDK, deployment target
macOS 15; macOS 26+ APIs such as Liquid Glass are guarded with `#available`).
It captures HDMI from Blackmagic UltraStudio devices, publishes each camera
as a virtual camera for meeting apps, and records the camera original.
Typical use: one or two cameras in a video meeting, sometimes a backup or
standalone recording.

The new interface was just built from the round-4 design
(`docs/mockups/r4/`, start with `index.html` and `spec.html`). The user ran
the real app and found "lots of little UI bugs": the sidebar didn't open on
click (fixed), the inspector was cramped (reworked), and font sizes and the
hierarchy of items weren't logical. This round is a polish pass, not a
redesign: keep the structure, fix what's wrong, make it feel like a
first-party macOS 27 app in both light and dark.

## Structure (keep)

- Main window: `NavigationSplitView` with the session sidebar (left), camera
  pictures with a channel strip under each (center), an on-demand inspector
  (right, ⌥⌘I) and a status bar (bottom).
- Toolbar: Start/Stop camera(s), Record, layout picker (only with 2+ cameras),
  collapse strips, inspector. Program mode adds cut buttons and Auto.
- Menu bar item: live preview plus compact native menu rows.
- Settings (6 panes), Diagnostics window, Help window.

## Decisions already made (don't relitigate)

- The user-facing noun is **Camera** (never "Feed").
- D1 a picture click selects, never cuts. D2 format changes are allowed while
  a meeting app uses the camera ("Updating output…"). D3 Stop Camera asks
  first only when recording or on air. D5 ⋯ is a menu; the inspector opens on
  demand. D7 selection and focus are one blue ring. D8 red is only for ON AIR
  and recording; no consumer app names in the UI.
- Deferred features show as "Coming later" (backup automation, consumer
  count, director timeline, sparklines). Don't propose building them.

## Evidence

- Real app, light, live camera (no HDMI signal connected):
  `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-tour/latest-Light/`
- Real app, dark: `.../ui-tour/latest-Dark/`
  File names say what each capture is (`01-main-sidebar`, `08-live-started`,
  `11-settings-General`, …). Files ending `-2`, `-3` are other windows or
  menus open at the same moment.
- Offscreen renders with fixture data (two and four cameras, recording,
  Program mode, problems, every component, light and dark):
  `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-verify/latest/png/`
  The offscreen renderer can't draw the sidebar (it appears black) or the
  inspector column; judge those from the real-app tours.
- Code: `Sources/App/UI*.swift` (views), `Sources/App/UIPresentation.swift`
  (all wording and state rules), `Sources/App/UIStyle.swift` (shared styles).

Images are large: view them at reduced size where you can (for example
`sips -Z 1400 in.png --out /tmp/<you>/out.png`). Don't modify any file
outside `docs/ui-polish/` and your own `/tmp/<you>/` scratch folder. Don't run
the app, build scripts or tests: another session is using them.

## What to report

Write your findings to `docs/ui-polish/<your-lens>.md`. For each finding:

- **ID** (your lens prefix and a number), **severity** (P1 broken or
  misleading, P2 clearly wrong or inconsistent, P3 polish).
- **Where**: the screenshot file(s) and `file:line`.
- **What's wrong**, in one or two sentences, from the user's point of view.
- **Fix**: a concrete change (the SwiftUI modifier, font style, wording or
  layout), small enough to implement directly. Prefer native controls and
  system styles over custom drawing.

Verify each finding against the code before reporting it; drop anything you
can't tie to a real cause. Quality over quantity: 10 sharp findings beat 40
vague ones. End with a short "top 5" list.

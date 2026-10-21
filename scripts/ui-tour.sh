#!/bin/bash
# Drives the real built app through its windows and states the way a person
# would (toolbar, menus, Settings tabs, menu bar item) and captures each step.
# Only Ultracam's own windows are captured, by window ID: never the screen.
# Needs Accessibility and Screen Recording permission for the terminal.
# Saves Ultracam's preferences first and restores them after the tour.
# APPEARANCE=Dark runs the tour in dark mode. LIVE=1 also starts and stops the
# camera on the real UltraStudio input. Quit Ultracam before running.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo 'Usage: ui-tour.sh' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
app="${APP:-$external_root/agent-work/ultracam/Ultracam.app}"
binary="$app/Contents/MacOS/Ultracam"
[[ -x "$binary" ]] || { echo "Built app not found at $app" >&2; exit 1; }
if pgrep -x Ultracam >/dev/null; then
  echo 'Quit Ultracam before running the tour.' >&2
  exit 1
fi
appearance="${APPEARANCE:-Light}"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
out_root="$external_root/agent-work/build/ultracam/ui-tour"
out="$out_root/$run_id-$appearance"
mkdir -p "$out"
ln -sfn "$run_id-$appearance" "$out_root/latest-$appearance"

xcrun swiftc -O "$task_root/Tools/UITour/windows.swift" -o "$out/windows" 2>"$out/windows-build.log"
xcrun swiftc -O "$task_root/Tools/UITour/click.swift" -o "$out/click" 2>>"$out/windows-build.log"
defaults export org.ultracam.app "$out/preferences-before.plist" 2>/dev/null || true

pid=""
finish() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [[ -f "$out/preferences-before.plist" ]]; then defaults import org.ultracam.app "$out/preferences-before.plist"; fi
}
trap finish EXIT

ui() { osascript -e "tell application \"System Events\" to tell process \"Ultracam\" to $1" 2>>"$out/osascript.log"; }
menu() { ui "click menu item \"$2\" of menu \"$1\" of menu bar 1" >/dev/null || echo "missing menu item: $1 › $2" | tee -a "$out/missing.txt"; }
toolbar() { ui "click (first UI element of toolbar 1 of window 1 whose description is \"$1\")" >/dev/null || echo "missing toolbar item: $1" | tee -a "$out/missing.txt"; }
# The sidebar toggle moves into the sidebar's own column while the sidebar is open,
# so its position (not its accessibility label) says whether the sidebar is shown.
sidebar_open() {
  local window_x toggle_x
  window_x=$(ui "get item 1 of (get position of window 1)")
  toggle_x=$(ui "get item 1 of (get position of UI element 1 of toolbar 1 of window 1)")
  (( toggle_x - window_x > 150 ))
}
# Clicks the sidebar toggle with a real mouse click and checks the sidebar followed.
click_sidebar_toggle() {
  local before=closed after=closed x y
  sidebar_open && before=open
  x=$(ui "get item 1 of (get position of UI element 1 of toolbar 1 of window 1)")
  y=$(ui "get item 2 of (get position of UI element 1 of toolbar 1 of window 1)")
  "$out/click" $((x + 22)) $((y + 26))
  sleep 1
  sidebar_open && after=open
  if [[ "$before" == "$after" ]]; then echo "sidebar toggle ignored: stayed $after" | tee -a "$out/missing.txt"; fi
}

# Closes the window with this title by its close button, never the main window by accident.
close_window() {
  ui "click (first button of (first window whose name contains \"$1\") whose subrole is \"AXCloseButton\")" >/dev/null ||
    echo "could not close window: $1" | tee -a "$out/missing.txt"
}

# capture NAME [TITLE]: every on-screen Ultracam window whose title contains TITLE
# (all windows when TITLE is empty), including open menus.
capture() {
  local name="$1" title="${2:-}" n=0
  sleep "${SETTLE:-1.2}"
  while IFS=$'\t' read -r id layer window_title; do
    if [[ -n "$title" && "$window_title" != *"$title"* && "$layer" == 0 ]]; then continue; fi
    n=$((n + 1))
    local suffix=""; [[ $n -gt 1 ]] && suffix="-$n"
    screencapture -x -o -l "$id" "$out/$name$suffix.png"
  done < <("$out/windows" Ultracam)
  printf '%s\n' "$name" >> "$out/steps.txt"
}

"$binary" --ui-appearance "$(echo "$appearance" | tr "[:upper:]" "[:lower:]")" > "$out/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 30); do
  ui "get name of menu bar 1" >/dev/null 2>&1 && break
  sleep 0.5
done
sleep 1
# macOS restores a closed main window as closed; open it the way a person would (⌘0).
if ! ui "get toolbar 1 of window 1" >/dev/null 2>&1; then
  menu Window "Main Window"
  sleep 1
fi
ui "set position of window 1 to {80, 60}" >/dev/null
ui "set size of window 1 to {1440, 900}" >/dev/null

# Main window: sidebar and inspector in every combination.
ui "set frontmost to true" >/dev/null
sidebar_open || click_sidebar_toggle
capture 01-main-sidebar Ultracam
toolbar Inspector
capture 02-main-sidebar-inspector Ultracam
click_sidebar_toggle
capture 03-main-inspector Ultracam
click_sidebar_toggle
capture 04-main-sidebar-inspector-reopened Ultracam
click_sidebar_toggle
click_sidebar_toggle
toolbar Inspector
menu View "Collapse All Strips"
capture 05-main-collapsed Ultracam
menu View "Expand All Strips"
for layout in "Single" "Side by Side" "Program View" "Four Up"; do
  menu View "$layout"
  capture "06-layout-${layout// /-}" Ultracam
done
menu View "Single"

# The smallest window, with both side columns open.
ui "set size of window 1 to {980, 680}" >/dev/null
toolbar Inspector
capture 07-main-minimum-size Ultracam
toolbar Inspector
ui "set size of window 1 to {1440, 900}" >/dev/null

if [[ "${LIVE:-0}" == 1 ]]; then
  menu Camera "Start All Cameras"
  SETTLE=5 capture 08-live-started Ultracam
  toolbar Inspector
  capture 08-live-inspector Ultracam
  toolbar Inspector
  menu Camera "Stop All Cameras"
  SETTLE=3 capture 08-live-stopped Ultracam
fi

# Menus from the menu bar.
# Opening a menu blocks the scripting call until the menu closes, so don't wait for it.
open_menu() {
  osascript -e "ignoring application responses" \
    -e "tell application \"System Events\" to tell process \"Ultracam\" to click $1" \
    -e "end ignoring" >/dev/null 2>>"$out/osascript.log"
}
for name in Camera Record Program View; do
  open_menu "menu bar item \"$name\" of menu bar 1"
  capture "09-menu-$name"
  ui "key code 53" >/dev/null
done
open_menu "menu bar item 1 of menu bar 2"
SETTLE=2 capture 10-menu-bar-extra
ui "key code 53" >/dev/null

# Settings, every pane.
ui "keystroke \",\" using command down" >/dev/null
sleep 1
for pane in General Recording Camera Switcher Monitor Advanced; do
  ui "click button \"$pane\" of toolbar 1 of window 1" >/dev/null || echo "missing settings pane: $pane" | tee -a "$out/missing.txt"
  capture "11-settings-$pane" "$pane"
done
close_window "Advanced"

menu Window Diagnostics
capture 12-diagnostics Diagnostics
close_window Diagnostics
menu Help "Ultracam Help"
capture 13-help Help
close_window "Ultracam Help"

printf 'UI tour (%s): %s images in %s\n' "$appearance" "$(ls "$out"/*.png | wc -l | tr -d ' ')" "$out"
if [[ -s "$out/missing.txt" ]]; then cat "$out/missing.txt"; fi

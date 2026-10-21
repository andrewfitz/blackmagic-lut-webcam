#!/bin/bash
# Paced synthetic-only qualification. Default is a short integration run.
set -euo pipefail
seconds=30
feeds=4
width=3840
height=2160
fps=29.97
codec=both
mode=compare
pipeline=actual
false_color=off
regressions=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) seconds="${2:?seconds required}"; shift 2 ;;
    --feeds) feeds="${2:?feeds required}"; shift 2 ;;
    --width) width="${2:?width required}"; shift 2 ;;
    --height) height="${2:?height required}"; shift 2 ;;
    --fps) fps="${2:?fps required}"; shift 2 ;;
    --codec) codec="${2:?codec required}"; shift 2 ;;
    --false-color) false_color="${2:?false color required}"; shift 2 ;;
    --pipeline) pipeline="${2:?pipeline required}"; shift 2 ;;
    --mode) mode="${2:?mode required}"; shift 2 ;;
    --regressions) regressions=true; shift ;;
    *) echo 'Usage: monitor-tools-stress.sh [--seconds N] [--feeds 1|2|4] [--width W --height H] [--fps 29.97|59.94] [--codec both|ProRes|HEVC] [--mode compare|off|enabled] [--pipeline synthetic|actual] [--false-color off|logc3|logc4|sony-slog3-sgamut3cine|sony-slog3-sgamut3] [--regressions]' >&2; exit 2 ;;
  esac
done
[[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 1 && "$seconds" -le 7200 ]] || { echo 'seconds must be an integer in 1...7200' >&2; exit 2; }
[[ "$feeds" == 1 || "$feeds" == 2 || "$feeds" == 4 ]] || { echo 'feeds must be 1, 2, or 4' >&2; exit 2; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$task_root/scripts/monitor-tools-smoke.sh" --seconds "$seconds" --feeds "$feeds" --width "$width" --height "$height" --format v210 --fps "$fps"
bash "$task_root/scripts/monitor-tools-recording.sh" --seconds "$seconds" --feeds "$feeds" --width "$width" --height "$height" --fps "$fps" --codec "$codec" --mode "$mode" --pipeline "$pipeline" --false-color "$false_color"
if [[ "$regressions" == true ]]; then
  # Existing codec/timecode/audio tests and interrupted-container recovery are reused.
  # These establish regressions separately; they are not a concurrent enabled/off comparison.
  bash "$task_root/scripts/test.sh"
  bash "$task_root/scripts/recording-recovery-smoke.sh"
fi

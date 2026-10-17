#!/bin/bash
# Build by default. --run explicitly exercises an already approved extension;
# --full additionally checks 4K ten-bit x422/v210 at both rates. Ad-hoc producer
# authorization requires the explicit local development extension build.
# --consumer requests only the virtual source for 20 seconds; the running host
# may start physical capture automatically. It inspects metadata, never pixels.
# This script never installs or activates extensions.
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --run && "$1" != --full && "$1" != --consumer ) ]]; then
  echo 'Usage: camera-smoke.sh [--run | --full | --consumer]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -q ' on /Volumes/8TB '; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$"
smoke_root="$external_root/agent-work/build/ultrastudio-lut-e2e/cmio-smoke/$run_id"
mkdir -p "$TMPDIR" "$smoke_root/modules"
compile_log="$smoke_root/compile.log"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$smoke_root/modules" \
  "$task_root/Sources/Shared/VideoContract.swift" "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root/Sources/Shared/VirtualCameraRegistry.swift" \
  "$task_root/Sources/Shared/CubeLUT.swift" \
  "$task_root/Sources/Shared/NaturalTalkingHeadAutoSwitcher.swift" \
  "$task_root/Sources/App/AppSettingsStore.swift" \
  "$task_root/Sources/App/LUTProcessor.swift" \
  "$task_root/Sources/App/CameraSink.swift" "$task_root/Sources/App/GPURawFrameCopy.swift" \
  "$task_root/Sources/App/SharedMetalBuffer.swift" "$task_root/Tools/CameraSmoke/main.swift" \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Metal \
  -o "$smoke_root/camera-smoke" > "$compile_log" 2>&1 || { cat "$compile_log"; exit 1; }
if ! codesign --force --sign - --identifier org.ultrastudiolut.app "$smoke_root/camera-smoke" >> "$compile_log" 2>&1; then
  cat "$compile_log" >&2
  exit 1
fi
if ! codesign --verify --strict "$smoke_root/camera-smoke" >> "$compile_log" 2>&1; then
  cat "$compile_log" >&2
  exit 1
fi
echo "Synthetic camera helper built: $smoke_root/camera-smoke"
if [[ "${1:-}" == --run || "${1:-}" == --full || "${1:-}" == --consumer ]]; then
  run_log="$smoke_root/run.log"
  arguments=(--run)
  if [[ "$1" == --full ]]; then arguments+=(--full); fi
  if [[ "$1" == --consumer ]]; then arguments=(--consumer 20); fi
  "$smoke_root/camera-smoke" "${arguments[@]}" > "$run_log" 2>&1 || { cat "$run_log"; exit 1; }
  cat "$run_log"
fi

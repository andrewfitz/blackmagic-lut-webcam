#!/bin/bash
# Build by default. --run explicitly exercises an already approved extension;
# --full additionally checks 4K ten-bit x422/v210 at both rates. Ad-hoc producer
# authorization requires the explicit local development extension build.
# This script never installs/activates extensions or opens physical devices.
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
smoke_root="$external_root/agent-work/build/ultrastudio-lut-e2e/cmio-smoke"
mkdir -p "$TMPDIR" "$smoke_root/modules" "$smoke_root/logs"
receipt="$(date -u +%Y%m%dT%H%M%SZ)"
compile_log="$smoke_root/logs/compile-$receipt.log"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$smoke_root/modules" \
  "$task_root/Sources/Shared/VideoContract.swift" "$task_root/Sources/Shared/VideoBufferLayout.swift" \
  "$task_root/Sources/App/CameraSink.swift" "$task_root/Sources/App/GPURawFrameCopy.swift" \
  "$task_root/Sources/App/SharedMetalBuffer.swift" "$task_root/Tools/CameraSmoke/main.swift" \
  -o "$smoke_root/camera-smoke" > "$compile_log" 2>&1 || { cat "$compile_log"; exit 1; }
codesign --force --sign - --identifier org.ultrastudiolut.app "$smoke_root/camera-smoke" >> "$compile_log" 2>&1
codesign --verify --strict "$smoke_root/camera-smoke" >> "$compile_log" 2>&1
echo "Synthetic camera helper built: $smoke_root/camera-smoke"
if [[ "${1:-}" == --run || "${1:-}" == --full || "${1:-}" == --consumer ]]; then
  run_log="$smoke_root/logs/run-$receipt.log"
  arguments=(--run)
  if [[ "$1" == --full ]]; then arguments+=(--full); fi
  if [[ "$1" == --consumer ]]; then arguments=(--consumer 20); fi
  "$smoke_root/camera-smoke" "${arguments[@]}" > "$run_log" 2>&1 || { cat "$run_log"; exit 1; }
  cat "$run_log"
fi

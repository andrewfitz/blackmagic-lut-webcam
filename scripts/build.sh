#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -q ' on /Volumes/8TB '; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
mkdir -p "$TMPDIR" "$external_root/agent-work/ultrastudio-lut/logs"
python3 "$task_root/scripts/generate_project.py"
args=(-project "$task_root/UltraStudioLUT.xcodeproj" -scheme 'UltraStudio LUT' -configuration Debug -derivedDataPath "$external_root/agent-work/build/ultrastudio-lut" -jobs 4)
if [[ "${1:-}" == --signed ]]; then
  : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID.}"
  args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild "${args[@]}" build > "$external_root/agent-work/ultrastudio-lut/logs/build.log" 2>&1 || {
  /usr/bin/grep -E 'error:|warning:|BUILD FAILED' "$external_root/agent-work/ultrastudio-lut/logs/build.log" || true
  exit 1
}
echo "Built: $external_root/agent-work/build/ultrastudio-lut/Build/Products/Debug/UltraStudio LUT.app"

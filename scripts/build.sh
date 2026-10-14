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
bash "$task_root/scripts/fetch-decklink-sdk.sh"
python3 "$task_root/scripts/generate_project.py"
configuration=Release
signed=false
local_development=false
for option in "$@"; do
  case "$option" in
    --debug) configuration=Debug ;;
    --signed) signed=true ;;
    --local-development) local_development=true ;;
    *) echo "Unknown build option: $option" >&2; exit 1 ;;
  esac
done
if [[ "$signed" == true && "$local_development" == true ]]; then
  echo 'Choose either --signed or --local-development.' >&2
  exit 1
fi
args=(-project "$task_root/UltraStudioLUT.xcodeproj" -scheme 'UltraStudio LUT' -configuration "$configuration" -derivedDataPath "$external_root/agent-work/build/ultrastudio-lut" -jobs 4)
if [[ "$signed" == true ]]; then
  : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID.}"
  args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
if [[ "$local_development" == true ]]; then
  args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) UDL_LOCAL_DEVELOPMENT')
fi
build_log="$external_root/agent-work/ultrastudio-lut/logs/build-$(date -u +%Y%m%dT%H%M%SZ).log"
ln -sfn "$(basename "$build_log")" "$external_root/agent-work/ultrastudio-lut/logs/build.log"
xcodebuild "${args[@]}" build > "$build_log" 2>&1 || {
  /usr/bin/grep -E 'error:|warning:|BUILD FAILED' "$build_log" || true
  exit 1
}
product="$external_root/agent-work/build/ultrastudio-lut/Build/Products/$configuration/UltraStudio LUT.app"
python3 "$task_root/scripts/validate_bundle.py" "$product"
if [[ "$local_development" == true ]]; then
  python3 "$task_root/scripts/prepare_local_build.py" "$product" \
    "$external_root/agent-work/ultrastudio-lut/local-development/UltraStudio LUT.app"
else
  echo "Built: $product"
fi

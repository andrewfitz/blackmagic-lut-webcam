#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -q ' on /Volumes/8TB '; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
test_root="$external_root/agent-work/build/ultrastudio-lut/tests"
mkdir -p "$TMPDIR" "$test_root/modules" "$external_root/agent-work/ultrastudio-lut/logs"
export ULTRASTUDIO_LUT_SHADER="$task_root/Sources/App/LUTShaders.metal"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -O -swift-version 5 -module-cache-path "$test_root/modules" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$task_root"/Sources/Shared/*.swift "$task_root/Sources/App/LUTProcessor.swift" \
  "$task_root/Tests/main.swift" -o "$test_root/lut-tests"
"$test_root/lut-tests" > "$external_root/agent-work/ultrastudio-lut/logs/tests.log" 2>&1 || {
  cat "$external_root/agent-work/ultrastudio-lut/logs/tests.log"
  exit 1
}
tail -5 "$external_root/agent-work/ultrastudio-lut/logs/tests.log"

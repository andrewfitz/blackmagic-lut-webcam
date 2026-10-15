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
bash "$task_root/scripts/fetch-decklink-sdk.sh"
sdk_dir="${DECKLINK_SDK_DIR:-$external_root/cache/ultrastudio-lut/decklink-sdk}"
export ULTRASTUDIO_LUT_SHADER="$task_root/Sources/App/LUTShaders.metal"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
receipt="$(date -u +%Y%m%dT%H%M%SZ)"
compile_log="$external_root/agent-work/ultrastudio-lut/logs/test-compile-$receipt.log"
test_log="$external_root/agent-work/ultrastudio-lut/logs/tests-$receipt.log"
if [[ -f "$external_root/agent-work/ultrastudio-lut/logs/tests.log" && ! -L "$external_root/agent-work/ultrastudio-lut/logs/tests.log" ]]; then
  mv "$external_root/agent-work/ultrastudio-lut/logs/tests.log" "$external_root/agent-work/ultrastudio-lut/logs/tests-pre-receipts-$receipt.log"
fi
ln -sfn "$(basename "$test_log")" "$external_root/agent-work/ultrastudio-lut/logs/tests.log"
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -DUDL_BACKEND_TESTING \
  -fmodules-cache-path="$test_root/modules" -I "$sdk_dir" \
  -c "$task_root/Sources/DeckLinkBackend/UDLBackend.mm" -o "$test_root/UDLBackend.o" > "$compile_log" 2>&1 || {
  cat "$compile_log"; exit 1
}
xcrun clang++ -std=c++17 -I "$sdk_dir" -c "$sdk_dir/DeckLinkAPIDispatch.cpp" \
  -o "$test_root/DeckLinkAPIDispatch.o" >> "$compile_log" 2>&1 || {
  cat "$compile_log"; exit 1
}
xcrun swiftc -O -swift-version 5 -module-cache-path "$test_root/modules" \
  -D CAPTURE_LIFECYCLE_TESTS -Xcc -DUDL_BACKEND_TESTING \
  -import-objc-header "$task_root/Sources/DeckLinkBackend/BridgingHeader.h" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  -I "$libraries" -L "$libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$libraries" \
  "$task_root"/Sources/Shared/*.swift "$task_root/Sources/App/LUTProcessor.swift" \
  "$task_root"/Sources/Recording/*.swift \
  "$task_root/Sources/App/CameraSink.swift" "$task_root/Sources/App/CaptureController.swift" \
  "$task_root/Sources/App/VideoPreview.swift" "$task_root/Sources/App/SharedMetalBuffer.swift" \
  "$task_root/Sources/App/GPURawFrameCopy.swift" \
  "$task_root/Sources/App/AppSettingsStore.swift" \
  "$task_root/Sources/App/RecordingModel.swift" \
  "$task_root/Sources/App/AutomaticFeedPolicy.swift" \
  "$task_root/Sources/App/CameraDemandMonitor.swift" \
  "$task_root/Sources/App/ExtensionInstaller.swift" \
  "$task_root/Sources/CameraExtension/CameraProvider.swift" \
  "$task_root"/Tests/*.swift "$test_root/UDLBackend.o" "$test_root/DeckLinkAPIDispatch.o" -lc++ \
  -o "$test_root/lut-tests" >> "$compile_log" 2>&1 || {
  cat "$compile_log"
  exit 1
}
"$test_root/lut-tests" > "$test_log" 2>&1 || {
  cat "$test_log"
  exit 1
}
tail -5 "$test_log"

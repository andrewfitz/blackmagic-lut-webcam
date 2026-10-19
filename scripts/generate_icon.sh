#!/bin/bash
# Generate all macOS AppIcon representations from the original artwork.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
source_icon="$task_root/Assets/Ultracam-icon.png"
source_vector="$task_root/Assets/Ultracam-icon.svg"
catalog="$task_root/Config/Assets.xcassets"
icon_set="$catalog/AppIcon.appiconset"
mkdir -p "$icon_set"
if [[ -f "$source_vector" ]]; then
  if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo 'Install librsvg to render the SVG artwork (brew install librsvg).' >&2
    exit 1
  fi
  rsvg-convert --width=1024 --height=1024 --output="$source_icon" "$source_vector"
fi
for logical_size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((logical_size * scale))
    sips -z "$pixels" "$pixels" "$source_icon" \
      --out "$icon_set/icon_${logical_size}x${logical_size}@${scale}x.png" >/dev/null
  done
done
python3 - "$catalog" <<'PY'
import json
from pathlib import Path
import sys

catalog = Path(sys.argv[1])
metadata = {"version": 1, "author": "xcode"}
(catalog / "Contents.json").write_text(json.dumps({"info": metadata}, indent=2) + "\n")
images = [
    {"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x",
     "filename": f"icon_{size}x{size}@{scale}x.png"}
    for size in (16, 32, 128, 256, 512) for scale in (1, 2)
]
(catalog / "AppIcon.appiconset/Contents.json").write_text(
    json.dumps({"images": images, "info": metadata}, indent=2) + "\n")
PY
echo "Generated macOS icon catalog: $catalog"

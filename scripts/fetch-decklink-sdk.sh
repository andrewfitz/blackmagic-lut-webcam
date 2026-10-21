#!/bin/bash
set -euo pipefail
# Blackmagic's permissively licensed SDK interfaces as shipped by the official
# OBS upstream. Download only the SDK files, never OBS's GPL implementation.
# The pinned commit and SHA-256 checks make the external cache reproducible.
external_root=/Volumes/8TB/cinesomatic-director-work
if ! mount | /usr/bin/grep -F ' on /Volumes/8TB ' > /dev/null; then
  echo 'External drive /Volumes/8TB is not mounted.' >&2
  exit 1
fi
export TMPDIR="$external_root/tmp"
sdk_dir="${DECKLINK_SDK_DIR:-$external_root/cache/ultracam/decklink-sdk}"
sdk_dir="$(python3 - "$external_root" "$sdk_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
candidate = Path(sys.argv[2]).expanduser()
try:
    resolved = candidate.resolve(strict=False)
except OSError as error:
    raise SystemExit(f"Cannot resolve DECKLINK_SDK_DIR: {error}")
if resolved == root or not resolved.is_relative_to(root):
    raise SystemExit("DECKLINK_SDK_DIR must be inside the external project workspace.")
print(resolved)
PY
)"
mkdir -p "$TMPDIR" "$sdk_dir"
python3 - "$sdk_dir" <<'PYTHON'
import hashlib
import os
import pathlib
import sys
import tempfile
import urllib.request

commit = "f082210c177a03572cace88c168d0f32d8cde39e"
base = f"https://raw.githubusercontent.com/obsproject/obs-studio/{commit}/plugins/decklink/mac/decklink-sdk"
files = {
    "DeckLinkAPI.h": "945b6f84f600e204dd5297408a7a21092189c6a907a2ace7ed63be595c9d7fe6",
    "DeckLinkAPIConfiguration.h": "53dfc28d5ed34fc7bb761aee2f129e055ded588e21868328cb3e4447287d1bd3",
    "DeckLinkAPIDeckControl.h": "88483e829fb4930663ca0015f1a67b91861dda387c0ab1980601548229cdf031",
    "DeckLinkAPIDiscovery.h": "eec704320e88e75d25df17b5740c33a0aebdda078bb40faf431dc23204653339",
    "DeckLinkAPIDispatch.cpp": "05132032276cb4f96f4a185bb3b0270c47574ea1889ad77071c4a69cd7343643",
    "DeckLinkAPIModes.h": "555168a6066f37cc3bc540b34a54bb4127ae9a04341673390b3bfaba2481af4f",
    "DeckLinkAPIStreaming.h": "5443b14fb101e4638541bcc208af2809ef54ad775b7e1421f73f31273fc7edf1",
    "DeckLinkAPITypes.h": "ec3f0d7e78b366a0bc0245b2f7c5225c8a4e0ab02f3e26e581d357d480aabc70",
    "DeckLinkAPIVersion.h": "db32f6be4188472ae9fd021527265d4d7893bf77e772f4cd4cf8fcb751cf1f6f",
}
destination = pathlib.Path(sys.argv[1])
if destination.is_symlink():
    raise SystemExit("DECKLINK_SDK_DIR must not be a symlink.")


def atomic_write(path: pathlib.Path, payload: bytes) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
            temporary = pathlib.Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


for name, expected in files.items():
    target = destination / name
    if target.is_symlink():
        raise SystemExit(f"Refusing symlink in SDK cache: {target}")
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
        continue
    payload = urllib.request.urlopen(f"{base}/{name}", timeout=30).read()
    if hashlib.sha256(payload).hexdigest() != expected:
        raise SystemExit(f"Checksum mismatch for {name}; cache preserved.")
    # Retain the entire original copyright/license in every cached file.
    if b"-LICENSE-START-" not in payload or b"-LICENSE-END-" not in payload:
        raise SystemExit(f"Missing Blackmagic license in {name}; cache preserved.")
    atomic_write(target, payload)
atomic_write((destination / "SOURCE.txt"), (
    f"Blackmagic Desktop Video SDK 12.0 interfaces\n"
    f"Source: https://github.com/obsproject/obs-studio/tree/{commit}/plugins/decklink/mac/decklink-sdk\n"
    "Each SDK file preserves its full Blackmagic copyright and permissive license.\n"
    "Versioned SDK interfaces are loaded from the user's installed Desktop Video framework.\n"
).encode())
print(destination)
PYTHON

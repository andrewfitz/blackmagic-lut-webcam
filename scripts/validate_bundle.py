#!/usr/bin/env python3
"""Check the built camera package before an OS activation request."""
from pathlib import Path
import plistlib
import sys


def validate(app):
    app = Path(app)
    extension = app / "Contents/Library/SystemExtensions/org.ultrastudiolut.app.camera.systemextension"
    for bundle, identifier, kind in (
        (app, "org.ultrastudiolut.app", "APPL"),
        (extension, "org.ultrastudiolut.app.camera", "SYSX"),
    ):
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundlePackageType") != kind:
            raise ValueError(f"Incorrect bundle identity/type: {bundle}")
        usage = info.get("NSSystemExtensionUsageDescription")
        if not isinstance(usage, str) or not usage.strip():
            raise ValueError(f"Missing system-extension usage description: {bundle}")
        executable = info.get("CFBundleExecutable", "")
        if not executable or Path(executable).name != executable or not (bundle / "Contents/MacOS" / executable).is_file():
            raise ValueError(f"Missing bundle executable: {bundle}")
        if bundle == extension:
            service = info.get("CMIOExtension", {}).get("CMIOExtensionMachServiceName", "")
            if not service or "$(" in service:
                raise ValueError("Camera Mach service is missing or has unresolved build variables.")
    print("Camera bundle metadata validated.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate_bundle.py APP.app")
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error

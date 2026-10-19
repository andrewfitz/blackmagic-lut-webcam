#!/usr/bin/env python3
"""Check the built camera package before an OS activation request."""
from pathlib import Path
import plistlib
import subprocess
import sys


def validate(app):
    app = Path(app)
    extension = app / "Contents/Library/SystemExtensions/org.ultracam.app.camera.systemextension"
    for bundle, identifier, kind in (
        (app, "org.ultracam.app", "APPL"),
        (extension, "org.ultracam.app.camera", "SYSX"),
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
            signature = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                capture_output=True,
            )
            if signature.returncode == 0 and signature.stdout:
                entitlements = plistlib.loads(signature.stdout)
            else:
                # Unsigned builds still need to match the configured app group.
                template = Path(__file__).resolve().parents[1] / "Config/Camera.entitlements"
                entitlements = plistlib.loads(template.read_bytes())
            groups = entitlements.get("com.apple.security.application-groups", [])
            if not any(service.startswith(group + ".") for group in groups):
                raise ValueError("Camera Mach service must be prefixed with an entitled app group.")
    print("Camera bundle metadata validated.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate_bundle.py APP.app")
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error

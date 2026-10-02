#!/usr/bin/env python3
"""Prepare an opt-in, independently signed copy; never edit the source app."""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("application", type=Path)
parser.add_argument("--bundle-id", help="Give the test copy a separate application identity.")
parser.add_argument("--display-name", help="Label the copy clearly in the Dock and menus.")
parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE")
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
source = args.application.resolve(strict=True)
if source.suffix != ".app" or not (source / "Contents/Info.plist").is_file():
    parser.error("Provide the path to an application bundle.")
if source.is_relative_to(project / "build"):
    parser.error("Choose an original application, not an existing test copy.")
destination = project / "build/Trials" / source.name
if destination.exists():
    parser.error(f"Test copy already exists: {destination}. It will not be overwritten.")
subprocess.run(["zsh", str(project / "scripts/build.sh")], check=True)
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["ditto", str(source), str(destination)], check=True)
frameworks = destination / "Contents/Frameworks"
frameworks.mkdir(exist_ok=True)
library = frameworks / "CmdTabo.dylib"
shutil.copy2(project / "build/CmdTabo.dylib", library)
info_path = destination / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
if args.bundle_id:
    info["CFBundleIdentifier"] = args.bundle_id
if args.display_name:
    info["CFBundleName"] = args.display_name
    info["CFBundleDisplayName"] = args.display_name
environment = info.setdefault("LSEnvironment", {})
for entry in args.env:
    key, separator, value = entry.partition("=")
    if not separator or not key:
        parser.error("--env requires KEY=VALUE.")
    environment[key] = value
previous = environment.get("DYLD_INSERT_LIBRARIES", "")
environment["DYLD_INSERT_LIBRARIES"] = f"{previous}:" + str(library) if previous else str(library)
environment["CMDTABO_DEBUG"] = "1"
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(destination)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
print(f"Prepared test copy: {destination}")
print("The original app was not changed. Open this copy explicitly with open -n.")
print("The copy may share app-specific data with the original; separate bundle IDs isolate standard preferences.")
print("Ad-hoc signing can prevent apps that need protected entitlements from working.")

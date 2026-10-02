#!/bin/zsh
set -eu
project_dir=${0:A:h:h}
zsh "$project_dir/scripts/build.sh"
trial_bundle="$project_dir/build/CmdTaboTrial.app"
mkdir -p "$trial_bundle/Contents/MacOS" "$trial_bundle/Contents/Frameworks"
cp "$project_dir/build/CmdTabo.dylib" "$trial_bundle/Contents/Frameworks/CmdTabo.dylib"
xcrun clang -fobjc-arc -Wall -Wextra -framework AppKit "$project_dir/tests/TrialApp.m" \
    -o "$trial_bundle/Contents/MacOS/CmdTaboTrial"
cat > "$trial_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.cmdtabo.DynamicTrial</string>
<key>CFBundleExecutable</key><string>CmdTaboTrial</string>
<key>CFBundleName</key><string>CmdTaboTrial</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
if [[ "${1:-}" == "--launch-services" ]]; then
    python3 - "$trial_bundle" <<'PY'
import plistlib, sys
from pathlib import Path
bundle = Path(sys.argv[1]).resolve()
info = bundle / "Contents/Info.plist"
data = plistlib.loads(info.read_bytes())
data["LSEnvironment"] = {
    "DYLD_INSERT_LIBRARIES": str(bundle / "Contents/Frameworks/CmdTabo.dylib"),
    "CMDTABO_DEBUG": "1",
}
info.write_bytes(plistlib.dumps(data))
PY
fi
codesign --force --deep --sign - "$trial_bundle"
if [[ "${1:-}" == "--launch-services" ]]; then
    log_dir=$(mktemp -d /tmp/cmdtabo-test-log.XXXXXX)
    trial_log="$log_dir/stdout.log"
    trial_err="$log_dir/stderr.log"
    : > "$trial_log"
    : > "$trial_err"
    open -n -W --stdout "$trial_log" --stderr "$trial_err" "$trial_bundle"
    cat "$trial_log" "$trial_err"
    cp "$trial_log" "$project_dir/build/launch-services-test.log"
    cp "$trial_err" "$project_dir/build/launch-services-test.err"
    rg -q '^RESULT failures=0$' "$trial_log"
else
    env DYLD_INSERT_LIBRARIES="$trial_bundle/Contents/Frameworks/CmdTabo.dylib" CMDTABO_DEBUG=1 \
        "$trial_bundle/Contents/MacOS/CmdTaboTrial"
fi

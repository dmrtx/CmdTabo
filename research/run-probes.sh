#!/bin/zsh
set -eu
research_dir=${0:A:h}
probe_dir=$(mktemp -d /tmp/cmdtabo-probe.XXXXXX)
probe_bundle="$probe_dir/LaunchServicesProbe.app"
probe_exe="$probe_bundle/Contents/MacOS/LaunchServicesProbe"
mkdir -p "$probe_bundle/Contents/MacOS"
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.cmdtabo.LaunchServicesProbe</string>
<key>CFBundleExecutable</key><string>LaunchServicesProbe</string>
<key>CFBundleName</key><string>LaunchServicesProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -framework AppKit "$research_dir/LaunchServicesProbe.m" -o "$probe_exe"
codesign --force --sign - "$probe_bundle"
printf 'Disposable bundle: %s\n' "$probe_bundle"
"$probe_exe" --self-check
"$probe_exe" > "$probe_dir/cross-process.log" 2>&1 &
probe_pid=$!
trap 'kill "$probe_pid" 2>/dev/null || true' EXIT
sleep 2
probe_result=0
"$probe_exe" --probe "$probe_pid" || probe_result=$?
printf 'Cross-process result: %d (5 means mutation/readback failed)\n' "$probe_result"
wait "$probe_pid"
cat "$probe_dir/cross-process.log"
trap - EXIT

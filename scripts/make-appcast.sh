#!/usr/bin/env bash
# Run after packaging a clean release. Only public signatures leave the Keychain.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
source update-config.env
SPARKLE_BIN=${SPARKLE_BIN:-}
GENERATOR="${SPARKLE_BIN:+$SPARKLE_BIN/}generate_appcast"
ARCHIVE="$ROOT/build/releases/CmdTabo-${MARKETING_VERSION}-macos-arm64.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Package the release before generating the update feed." >&2
  exit 1
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmdtabo-appcast.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp "$ARCHIVE" "$WORK/"
if [[ -f appcast.xml ]]; then cp appcast.xml "$WORK/appcast.xml"; fi
"$GENERATOR" --account "$SPARKLE_KEY_ACCOUNT" --maximum-deltas 0 --maximum-versions 3 \
  --versions "$BUILD_NUMBER" \
  --download-url-prefix "https://github.com/dmrtx/CmdTabo/releases/download/v${MARKETING_VERSION}/" \
  --link "https://github.com/dmrtx/CmdTabo/releases/tag/v${MARKETING_VERSION}" "$WORK"
swift "$ROOT/scripts/verify-update.swift" "$WORK/appcast.xml" "$ARCHIVE" "$SPARKLE_PUBLIC_KEY"
cp "$WORK/appcast.xml" "$ROOT/build/releases/appcast.xml"
echo "Created build/releases/appcast.xml. Publish release assets before updating the feed on main."

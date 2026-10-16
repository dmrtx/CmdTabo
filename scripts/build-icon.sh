#!/usr/bin/env bash
# Derive the complete macOS icon set from the reviewed PNG master.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/assets/CmdTabo.png"
OUT="$ROOT/build/icon"
ICONSET="$OUT/CmdTabo.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$OUT/Icon.icns"
echo "Created build/icon/Icon.icns"

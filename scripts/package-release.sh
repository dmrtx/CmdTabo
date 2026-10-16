#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
if [[ "${SIGNING_MODE:-local}" != local ]]; then
  echo 'Releases require the pinned local signing certificate; ad hoc signing is development-only.' >&2
  exit 1
fi
# The initial downloadable build targets the validated architecture.
ARCHES=arm64 bash scripts/package-app.sh release
codesign --verify --deep --strict build/CmdTabo.app
python3 scripts/verify-code-signature.py build/CmdTabo.app
python3 scripts/release_archive.py build/CmdTabo.app "build/releases/CmdTabo-${MARKETING_VERSION}-macos-arm64.zip"
python3 scripts/audit-publication.py --history --archive "build/releases/CmdTabo-${MARKETING_VERSION}-macos-arm64.zip"

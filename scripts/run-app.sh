#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/scripts/package-app.sh" release
open "$ROOT/build/CmdTabo.app"

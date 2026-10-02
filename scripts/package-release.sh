#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
# The initial downloadable build targets the validated architecture.
ARCHES=arm64 bash scripts/package-app.sh release
codesign --verify --strict build/CmdTabo.app
python3 - <<'PY'
import hashlib
from pathlib import Path
import stat
import zipfile

version = next(line.split('=', 1)[1].strip() for line in Path('version.env').read_text().splitlines()
               if line.startswith('MARKETING_VERSION='))
app = Path('build/CmdTabo.app')
out = Path('build/releases')
out.mkdir(parents=True, exist_ok=True)
archive = out / f'CmdTabo-{version}-macos-arm64.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
    for path in [app, *sorted(app.rglob('*'))]:
        if path.is_symlink():
            raise SystemExit('Unexpected symlink in release bundle')
        name = path.relative_to(app.parent).as_posix() + ('/' if path.is_dir() else '')
        entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        entry.create_system = 3
        mode = stat.S_IFDIR | 0o755 if path.is_dir() else stat.S_IFREG | (0o755 if path.name == 'CmdTabo' else 0o644)
        entry.external_attr = mode << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        bundle.writestr(entry, b'' if path.is_dir() else path.read_bytes())
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(out / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
print(f'Created {archive}')
PY
python3 scripts/audit-publication.py --history --archive "build/releases/CmdTabo-${MARKETING_VERSION}-macos-arm64.zip"

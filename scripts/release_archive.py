#!/usr/bin/env python3
"""Create an app-only ZIP with deterministic metadata and safe framework links."""
import argparse
import hashlib
import os
from pathlib import Path
import posixpath
import stat
import sys
import tempfile
import zipfile


FRAMEWORK_ROOT = 'CmdTabo.app/Contents/Frameworks/Sparkle.framework'


def validate_archive_entries(entries):
    """Validate names, file types and the complete graph of relative symlinks.

    Entries contain (name, Unix mode, symlink payload or empty bytes). Directory
    entries may be implicit, but no archived file may sit under a symlink.
    Errors never include a path or payload, which may contain private data.
    """
    items = {}
    links = {}
    for name, mode, payload in entries:
        path = name.rstrip('/')
        if (not path or '\\' in name or any(ord(c) < 32 for c in name)
                or any(part in ('', '.', '..') for part in path.split('/'))
                or not (path == 'CmdTabo.app' or path.startswith('CmdTabo.app/'))):
            raise ValueError('unsafe archive entry path')
        if path in items:
            raise ValueError('duplicate archive entry')
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
            raise ValueError('unsupported archive file type')
        if (kind == stat.S_IFDIR and not name.endswith('/')) or (kind in (stat.S_IFREG, stat.S_IFLNK) and name.endswith('/')):
            raise ValueError('inconsistent archive file type')
        items[path] = stat.S_IFDIR if name.endswith('/') else kind
        if kind == stat.S_IFLNK:
            if not path.startswith(FRAMEWORK_ROOT + '/'):
                raise ValueError('symlink outside the permitted framework')
            try:
                target = payload.decode('utf-8')
            except UnicodeDecodeError:
                raise ValueError('invalid framework symlink target') from None
            if not target or target.startswith('/') or '\\' in target or any(ord(c) < 32 for c in target):
                raise ValueError('unsafe framework symlink target')
            links[path] = target

    for path in items:
        parent = posixpath.dirname(path)
        while parent:
            if parent in items and items[parent] != stat.S_IFDIR:
                raise ValueError('archive entry nested under a non-directory')
            parent = posixpath.dirname(parent)

    for path, target in links.items():
        hops = [0]

        def resolve(parts, current, visiting):
            for part in parts:
                if part in ('', '.'):
                    continue
                if part == '..':
                    if len(current) <= len(FRAMEWORK_ROOT.split('/')):
                        raise ValueError('framework symlink escapes its framework')
                    current.pop()
                    continue
                current.append(part)
                prefix = '/'.join(current)
                if prefix in links:
                    hops[0] += 1
                    if prefix in visiting or hops[0] > 40:
                        raise ValueError('cyclic or excessive framework symlink')
                    current = resolve(links[prefix].split('/'), current[:-1], visiting | {prefix})
            return current

        # Resolve components before '..': collapsing lexically first would miss
        # an escape through a valid directory symlink followed by a parent step.
        resolved = '/'.join(resolve(target.split('/'), posixpath.dirname(path).split('/'), {path}))
        if resolved not in items and not any(item.startswith(resolved + '/') for item in items):
            raise ValueError('dangling framework symlink')


def archive_app(app, archive):
    app, archive = Path(app), Path(archive)
    if app.name != 'CmdTabo.app' or app.is_symlink() or not app.is_dir():
        raise ValueError('expected a real CmdTabo.app directory')
    paths = [app]
    for directory, directories, files in os.walk(app, followlinks=False):
        directories.sort()
        files.sort()
        paths.extend(Path(directory) / name for name in [*directories, *files])
    entries = []
    for path in sorted(paths):
        source_mode = path.lstat().st_mode
        name = path.relative_to(app.parent).as_posix()
        if stat.S_ISLNK(source_mode):
            mode, payload = stat.S_IFLNK | 0o777, os.fsencode(os.readlink(path))
        elif stat.S_ISDIR(source_mode):
            mode, payload = stat.S_IFDIR | 0o755, b''
            name += '/'
        elif stat.S_ISREG(source_mode):
            mode, payload = stat.S_IFREG | (0o755 if source_mode & 0o111 else 0o644), path.read_bytes()
        else:
            raise ValueError('unsupported app file type')
        entries.append((name, mode, payload))
    validate_archive_entries(entries)
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=archive.parent, prefix='.release-', suffix='.zip', delete=False) as output:
            temporary = Path(output.name)
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
            for name, mode, payload in entries:
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = mode << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                bundle.writestr(entry, payload)
        temporary.replace(archive)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return hashlib.sha256(archive.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    digest = archive_app(args.app, args.archive)
    (args.archive.parent / 'SHA256SUMS.txt').write_text(f'{digest}  {args.archive.name}\n')
    print(f'Created {args.archive.name}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError, zipfile.BadZipFile) as error:
        print(f'Archive creation failed: {type(error).__name__}', file=sys.stderr)
        sys.exit(1)

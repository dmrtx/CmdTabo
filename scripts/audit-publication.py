#!/usr/bin/env python3
"""Read-only checks of the Git index, reachable history, and a release ZIP."""
import argparse
import ipaddress
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import zipfile


def git(*args, check=True):
    return subprocess.run(['git', *args], check=check, capture_output=True).stdout


def local_hints():
    hints = {Path.home().name, os.environ.get('USER', ''), socket.gethostname()}
    for command in [['scutil', '--get', 'ComputerName'], ['scutil', '--get', 'LocalHostName'],
                    ['git', 'config', '--global', 'user.name'], ['git', 'config', '--global', 'user.email']]:
        try:
            value = subprocess.run(command, capture_output=True, timeout=3).stdout.decode().strip()
            if value:
                hints.add(value)
        except (OSError, subprocess.TimeoutExpired):
            pass
    return [re.compile(r'(?<![\w.-])' + re.escape(value) + r'(?![\w.-])', re.I)
            for value in hints if len(value) >= 4]


PATTERNS = {
    'personal home path': r'(?:/Users/|/home/)[A-Za-z0-9_. -]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_. -]+\\',
    'email in file content': r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    'GitHub credential': r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b',
    'cloud access key': r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'API credential': r'\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|xox[baprs]-[A-Za-z0-9-]{20,})\b',
    'JSON web token': r'\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\b',
    'MAC address': r'(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}(?![A-Fa-f0-9])',
}
COMPILED = {name: re.compile(pattern) for name, pattern in PATTERNS.items()}
IPV4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
IPV6 = re.compile(r'(?<![\w:])(?:[0-9a-fA-F]{0,4}:){3,7}[0-9a-fA-F]{0,4}(?![\w:])')
FORBIDDEN_FILES = re.compile(r'(?:^|/)(?:build|dist|\.build|\.swiftpm|__MACOSX)(?:/|$)|'
                             r'(?:^|/)(?:\.DS_Store|\._[^/]+|\.env(?:\.[^/]+)?)(?:$|/)|'
                             r'\.(?:log|err|pem|key|p12|pfx|mobileprovision|provisionprofile|zip|dylib)$', re.I)


def findings(data, hints):
    text = data.decode('utf-8', errors='ignore')
    found = {name for name, pattern in COMPILED.items() if pattern.search(text)}
    if any(pattern.search(text) for pattern in hints):
        found.add('local identity text')
    for pattern in [IPV4, IPV6]:
        for match in pattern.finditer(text):
            try:
                ipaddress.ip_address(match.group())
                found.add('literal network address')
                break
            except ValueError:
                pass
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='Also inspect all reachable Git blobs and commit messages.')
    parser.add_argument('--archive', type=Path, help='Also inspect an app-only release ZIP.')
    args = parser.parse_args()
    git('rev-parse', '--git-dir')
    hints = local_hints()
    issues = []
    scanned = set()
    count = 0

    def inspect(label, data, path=None, source=True):
        nonlocal count
        count += 1
        if source and path and FORBIDDEN_FILES.search(path):
            issues.append((label, 'excluded file type or directory'))
        if source and b'\0' in data:
            issues.append((label, 'binary file in source Git history'))
        for reason in findings(data, hints):
            issues.append((label, reason))

    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        _, object_id, stage = metadata.decode().split()
        if stage != '0':
            issues.append(('index', 'unmerged entry'))
            continue
        path = name.decode()
        inspect('index:' + path, git('cat-file', 'blob', object_id), path)
        scanned.add(object_id)

    if args.history:
        for entry in git('rev-list', '--objects', '--all').decode().splitlines():
            object_id, _, path = entry.partition(' ')
            if object_id in scanned or git('cat-file', '-t', object_id).strip() != b'blob':
                continue
            inspect('history:' + (path or object_id[:12]), git('cat-file', 'blob', object_id), path)
            scanned.add(object_id)
        # Author/committer email metadata is intentionally permitted. Messages
        # and file contents are still checked for personal data and credentials.
        for commit in git('rev-list', '--all').decode().splitlines():
            inspect('commit:' + commit[:12], git('show', '-s', '--format=%B', commit))

    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            if archive.comment:
                issues.append(('archive', 'ZIP comment'))
            seen = set()
            for item in archive.infolist():
                path = item.filename
                if path in seen:
                    issues.append(('archive', 'duplicate entry'))
                seen.add(path)
                if not path.startswith('CmdTabo.app/') or '..' in path.split('/') or path.startswith('/'):
                    issues.append(('archive', 'unexpected or absolute entry path'))
                if item.extra or item.comment:
                    issues.append(('archive:' + path, 'extended ZIP metadata'))
                if item.is_dir():
                    continue
                if not (path in ['CmdTabo.app/Contents/Info.plist', 'CmdTabo.app/Contents/MacOS/CmdTabo',
                                 'CmdTabo.app/Contents/_CodeSignature/CodeResources']
                        or path.startswith('CmdTabo.app/Contents/Resources/')):
                    issues.append(('archive:' + path, 'unexpected bundled file'))
                inspect('archive:' + path, archive.read(item), source=False)
            if 'CmdTabo.app/Contents/MacOS/CmdTabo' not in seen:
                issues.append(('archive', 'missing app executable'))

    if issues:
        for label, reason in sorted(set(issues)):
            print(f'FAIL {label}: {reason}')
        print('Publication audit failed. Matched values are redacted.')
        return 1
    print(f'PASS publication audit: {count} items checked; no matching private data found.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f'Audit could not complete: {type(error).__name__}', file=sys.stderr)
        sys.exit(2)

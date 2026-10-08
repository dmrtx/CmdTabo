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
    # Push transfers the original objects, not the local replacement view.
    environment = {**os.environ, 'GIT_NO_REPLACE_OBJECTS': '1'}
    return subprocess.run(['git', *args], check=check, capture_output=True, env=environment).stdout


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
IPV4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\w|\.\d)')
IPV6 = re.compile(r'(?<![\w:])(?:[0-9a-fA-F]{0,4}:){3,7}[0-9a-fA-F]{0,4}(?![\w:])')
PUBLIC_EMAIL = re.compile(r'(?:\d+\+)?([A-Za-z0-9-]+(?:\[bot\])?)@users\.noreply\.github\.com', re.I)
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


def safe_label(label, hints):
    # A path may itself be the private value. Never interpolate such a label
    # into diagnostics, even when the reported failure is unrelated to privacy.
    if findings(label.encode('utf-8', errors='surrogateescape'), hints):
        return label.split(':', 1)[0] + ':[redacted path]'
    # Keep filenames containing control characters on one diagnostic line.
    return ''.join(character if character.isprintable() else '?' for character in label)


def public_identity(name, email):
    if (name, email) == ('GitHub', 'noreply' + '@' + 'github.com'):
        return True
    match = PUBLIC_EMAIL.fullmatch(email)
    return bool(match and name.casefold() == match.group(1).casefold())


def object_headers(data):
    """Unfold Git's space-prefixed continuations without discarding any bytes."""
    raw_headers, _, message = data.partition(b'\n\n')
    headers = []
    for line in raw_headers.split(b'\n'):
        if line.startswith(b' ') and headers:
            headers[-1] += b'\n' + line[1:]
        else:
            headers.append(line)
    return headers, message


def public_identity_header(header, role):
    identity = re.fullmatch(role + r' (.+) <([^<>]+)> (-?\d+) ([+-]\d{4})',
                            header.decode('utf-8', errors='replace'))
    return bool(identity and public_identity(*identity.groups()[:2]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='Also inspect reachable Git history and annotated tags.')
    parser.add_argument('--archive', type=Path, help='Also inspect an app-only release ZIP.')
    args = parser.parse_args()
    git('rev-parse', '--git-dir')
    hints = local_hints()
    issues = []
    scanned = set()
    count = 0

    def inspect_path(label, path, source=True):
        label = safe_label(label, hints)
        for reason in findings(path.encode('utf-8', errors='surrogateescape'), hints):
            issues.append((label, 'private data in path: ' + reason))
        if source and FORBIDDEN_FILES.search(path):
            issues.append((label, 'excluded file type or directory'))

    def inspect(label, data, source=True):
        nonlocal count
        count += 1
        label = safe_label(label, hints)
        if source and b'\0' in data:
            issues.append((label, 'binary file in source Git history'))
        for reason in findings(data, hints):
            issues.append((label, reason))

    def inspect_tag(label, data):
        headers, message = object_headers(data)
        taggers = []
        targets = []
        for header in headers:
            name, _, value = header.partition(b' ')
            if name == b'tagger':
                taggers.append(header)
            else:
                inspect(label, header)
                if name == b'object' and re.fullmatch(rb'[0-9a-f]{40}|[0-9a-f]{64}', value):
                    targets.append(value)
        if len(taggers) != 1 or not all(public_identity_header(header, 'tagger') for header in taggers):
            issues.append((label, 'non-public or malformed tagger identity'))
        # A validated noreply identity is metadata, not arbitrary file content.
        inspect(label, message)
        return targets

    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        _, object_id, stage = metadata.split()
        path = os.fsdecode(name)
        inspect_path('index:' + path, path)
        if stage != b'0':
            issues.append(('index', 'unmerged entry'))
            continue
        inspect('index:' + path, git('cat-file', 'blob', object_id))
        scanned.add(object_id)

    if args.history:
        # Ref aliases can differ from the name stored inside an annotated tag.
        for name in git('for-each-ref', '--format=%(refname)', 'refs/tags').splitlines():
            path = os.fsdecode(name)
            inspect_path('tag-ref:' + path, path, source=False)
        # rev-list --objects reports only one name for a reused blob. Walk
        # every distinct commit tree with NUL delimiters to retain renamed
        # paths, directory names, and filenames containing newlines.
        trees = git('log', '--all', '--format=%T').splitlines()
        paths = set()
        scanned_trees = set()

        def inspect_tree(tree):
            if tree in scanned_trees:
                return
            scanned_trees.add(tree)
            for entry in git('ls-tree', '-r', '-t', '-z', tree.decode()).split(b'\0'):
                if not entry:
                    continue
                metadata, name = entry.split(b'\t', 1)
                _, kind, object_id = metadata.split()
                path = os.fsdecode(name)
                if path not in paths:
                    inspect_path('history:' + path, path)
                    paths.add(path)
                if kind == b'tree':
                    scanned_trees.add(object_id)
                elif kind == b'blob' and object_id not in scanned:
                    inspect('history:' + path, git('cat-file', 'blob', object_id))
                    scanned.add(object_id)

        for tree in dict.fromkeys(trees):
            inspect_tree(tree)
        # Include direct blob refs and every reachable annotated tag, including
        # inner tags whose only remaining reference is another tag object.
        objects = list(reversed(git('rev-list', '--objects', '--all', '--no-object-names').splitlines()))
        visited = set()
        while objects:
            object_id = objects.pop()
            if object_id in visited:
                continue
            visited.add(object_id)
            kind = git('cat-file', '-t', object_id).strip()
            if kind == b'blob' and object_id not in scanned:
                inspect('history:' + object_id.decode()[:12], git('cat-file', 'blob', object_id))
                scanned.add(object_id)
            elif kind == b'tree':
                # Tags may publish trees that no reachable commit references.
                inspect_tree(object_id)
            elif kind == b'tag':
                label = 'tag:' + object_id.decode()[:12]
                objects.extend(inspect_tag(label, git('cat-file', 'tag', object_id)))
        # Public handles with GitHub noreply addresses are the only identities
        # permitted in author/committer metadata. Never print rejected values.
        for commit in git('rev-list', '--all').decode().splitlines():
            label = 'commit:' + commit[:12]
            headers, message = object_headers(git('cat-file', 'commit', commit))
            identities = {b'author': [], b'committer': []}
            for header in headers:
                name, _, value = header.partition(b' ')
                if name in identities:
                    identities[name].append(header)
                elif name == b'mergetag':
                    # A mergetag embeds annotated tag bytes without publishing
                    # a separate tag object/ref. Apply the same identity policy.
                    inspect_tag(label + ':mergetag', value)
                else:
                    inspect(label, header)
            if any(len(values) != 1 or not all(public_identity_header(header, role.decode()) for header in values)
                   for role, values in identities.items()):
                issues.append((label, 'non-public author or committer identity'))
            inspect(label, message)
            # The encoding header can declare a non-UTF-8 commit message. Keep
            # the raw scan, then also scan Git's normalized original message so
            # accented identity hints survive decoding. git() disables replaces.
            recoded = git('-c', 'i18n.logOutputEncoding=UTF-8', 'show', '-s', '--format=%B', commit)
            if recoded.rstrip(b'\n') != message.rstrip(b'\n'):
                inspect(label, recoded)

    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            if archive.comment:
                issues.append(('archive', 'ZIP comment'))
            seen = set()
            for item in archive.infolist():
                path = item.filename
                label = safe_label('archive:' + path, hints)
                inspect_path('archive:' + path, path, source=False)
                if path in seen:
                    issues.append(('archive', 'duplicate entry'))
                seen.add(path)
                if not path.startswith('CmdTabo.app/') or '..' in path.split('/') or path.startswith('/'):
                    issues.append(('archive', 'unexpected or absolute entry path'))
                if item.extra or item.comment:
                    issues.append((label, 'extended ZIP metadata'))
                if item.is_dir():
                    continue
                if not (path in ['CmdTabo.app/Contents/Info.plist', 'CmdTabo.app/Contents/MacOS/CmdTabo',
                                 'CmdTabo.app/Contents/_CodeSignature/CodeResources']
                        or path.startswith('CmdTabo.app/Contents/Resources/')):
                    issues.append((label, 'unexpected bundled file'))
                inspect(label, archive.read(item), source=False)
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

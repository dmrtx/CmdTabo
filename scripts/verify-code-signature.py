#!/usr/bin/env python3
"""Verify stable local identity, nested signatures and Sparkle-compatible flags."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PINS = dict(line.split('=', 1) for line in (ROOT / 'signing-config.env').read_text().splitlines()
            if line and not line.startswith('#'))
SHA1 = PINS['SIGNING_CERT_SHA1']
SHA256 = PINS['SIGNING_CERT_SHA256']
MACHO = {bytes.fromhex(value) for value in ('cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca')}


def command(*args, stdout_only=False):
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout if stdout_only else result.stdout + result.stderr


def verify_requirement(output, identifier, main=False):
    certificate_position = 'leaf' if main else '(?:leaf|root)'
    pattern = (r'designated => identifier (?:"' + re.escape(identifier) + r'"|' + re.escape(identifier)
               + r') and certificate ' + certificate_position + r' = H"(?i:' + SHA1 + r')"')
    # Reject added alternatives such as "or true" which would weaken future
    # identity checks even while the current object's certificate is correct.
    if re.fullmatch(pattern, output.strip()) is None:
        raise ValueError('The designated requirement must bind only this identifier and certificate')


def verify(app, bundle_id='local.cmdtabo.switcher'):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != bundle_id:
        raise ValueError('Unexpected app bundle identifier')
    command('codesign', '--verify', '--deep', '--strict', str(app))
    components = {app}
    frameworks = app / 'Contents/Frameworks'
    for path in frameworks.rglob('*'):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {'.framework', '.app', '.xpc'}:
            components.add(path)
        elif path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO:
                    components.add(path)
    # Verify each nested object independently; a valid outer seal is insufficient.
    with tempfile.TemporaryDirectory(prefix='cmdtabo-certificate-') as work:
        for component in sorted(components):
            metadata = command('codesign', '--display', '--verbose=4', str(component))
            flags = re.search(r'flags=0x([0-9a-fA-F]+)', metadata)
            if not flags or int(flags[1], 16) & (0x2 | 0x2000 | 0x10000):
                raise ValueError('Ad hoc signing, library validation or hardened runtime is incompatible with the local identity')
            if 'TeamIdentifier=not set' not in metadata:
                raise ValueError('A local certificate must not impersonate an Apple Team ID')
            identifiers = re.findall(r'^Identifier=(.+)$', metadata, re.MULTILINE)
            if len(identifiers) != 1:
                raise ValueError('Expected one code-signing identifier')
            identifier = identifiers[0]
            prefix = str(Path(work) / 'certificate-')
            command('codesign', '--display', '--extract-certificates=' + prefix, str(component))
            certificate = Path(prefix + '0').read_bytes()
            if hashlib.sha256(certificate).hexdigest().upper() != SHA256:
                raise ValueError('Code-signing certificate does not match the pinned identity')
            command('codesign', '--verify', '--strict', '-R', f'=certificate leaf = H"{SHA1}"', str(component))
            requirement = command('codesign', '--display', '-r-', str(component), stdout_only=True)
            verify_requirement(requirement, identifier, main=component == app)
            if component == app and identifier != bundle_id:
                raise ValueError('The application code-signing identifier changed')
            # Helpers/frameworks retain their own identifiers, never the main ID.
            plist = component / ('Resources/Info.plist' if component.suffix == '.framework' else 'Contents/Info.plist')
            if component != app and component.is_dir() and plist.is_file():
                identifier = plistlib.loads(plist.read_bytes())['CFBundleIdentifier']
                if f'Identifier={identifier}\n' not in metadata or identifier == bundle_id:
                    raise ValueError('A nested bundle lost its own signing identifier')
    print(f'PASS stable code identity and {len(components)} nested code objects.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--bundle-id', default='local.cmdtabo.switcher')
    args = parser.parse_args()
    verify(args.app, args.bundle_id)

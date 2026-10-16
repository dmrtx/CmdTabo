"""Signed update fixtures use fresh CryptoKit keys in memory, never Keychain."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / 'scripts' / 'verify-update.swift'
FIXTURE_SOURCE = r'''
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
let archiveURL = root.appendingPathComponent("CmdTabo-test-macos-arm64.zip")
let archive = try Data(contentsOf: archiveURL)
let key = Curve25519.Signing.PrivateKey()
let wrongKey = Curve25519.Signing.PrivateKey()
let archiveSignature = try key.signature(for: archive).base64EncodedString()
let archiveLength = archive.count + (mode == "archive-length" ? 1 : 0)
let signatureAttribute = mode == "missing-archive-signature" ? "" : "sparkle:edSignature=\"\(archiveSignature)\""
let enclosure = "<enclosure url=\"https://example.invalid/CmdTabo-test-macos-arm64.zip\" length=\"\(archiveLength)\" type=\"application/octet-stream\" \(signatureAttribute) />"
let enclosures = mode == "duplicate-enclosure" ? enclosure + enclosure : enclosure
let title = mode == "replacement-character" ? "Actualización \u{FFFD}" : "Actualización"
let doctype = mode == "doctype" ? "<!DOCTYPE rss [<!ENTITY fixture \"innocuous\">]>\n" : ""
let body = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + doctype +
    "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><title>" + title +
    "</title><item><sparkle:version>12</sparkle:version>" + enclosures + "</item></channel></rss>\n").utf8)
let signature = try key.signature(for: body).base64EncodedString()
let footer = Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.count)\n-->\n".utf8)
try (body + footer).write(to: root.appendingPathComponent("appcast.xml"))
// Only public keys leave this process. Private keys are never serialized.
let output = try JSONSerialization.data(withJSONObject: ["publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
                                                       "wrongKey": wrongKey.publicKey.rawRepresentation.base64EncodedString()])
print(String(decoding: output, as: UTF8.self))
'''


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'requires macOS CryptoKit and swiftc')
class VerifyUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compilation = tempfile.TemporaryDirectory(prefix='cmdtabo-verify-update-tests-')
        cls.addClassCleanup(cls.compilation.cleanup)
        root = Path(cls.compilation.name)
        cls.verifier = root / 'verify-update'
        cls.fixture = root / 'make-fixture'
        fixture_source = root / 'fixture.swift'
        fixture_source.write_text(FIXTURE_SOURCE)
        for source, executable in [(VERIFIER, cls.verifier), (fixture_source, cls.fixture)]:
            result = subprocess.run(['swiftc', '-module-cache-path', str(root / 'modules'),
                                     str(source), '-o', str(executable)], capture_output=True, text=True)
            if result.returncode:
                raise AssertionError('Swift fixture compilation failed:\n' + result.stderr)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cmdtabo-signed-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'CmdTabo-test-macos-arm64.zip'
        self.feed = self.root / 'appcast.xml'
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            bundle.writestr('CmdTabo.app/Contents/Resources/fixture.txt', 'innocuous')
        self.make_fixture()

    def make_fixture(self, mode='valid'):
        result = subprocess.run([str(self.fixture), str(self.root), mode], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        keys = json.loads(result.stdout)
        self.public_key, self.wrong_key = keys['publicKey'], keys['wrongKey']

    def verify(self, key=None):
        return subprocess.run([str(self.verifier), str(self.feed), str(self.archive), key or self.public_key],
                              capture_output=True, text=True)

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, 'FAIL signed update verification.\n')
        self.assertNotIn(str(self.root), result.stdout + result.stderr)

    def test_valid_signed_feed_and_archive_with_public_key_only(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS public-key verification', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_tampered_signed_feed_is_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().replace('Actualización'.encode(), b'Tampered title'))
        self.assert_rejected(self.verify())

    def test_tampered_archive_is_rejected(self):
        data = bytearray(self.archive.read_bytes())
        data[-1] ^= 1
        self.archive.write_bytes(data)
        self.assert_rejected(self.verify())

    def test_wrong_public_key_is_rejected(self):
        self.assert_rejected(self.verify(self.wrong_key))

    def test_altered_unsigned_footer_length_is_rejected(self):
        self.feed.write_bytes(re.sub(rb'length: (\d+)', lambda match: b'length: ' + str(int(match[1]) + 1).encode(),
                                    self.feed.read_bytes()))
        self.assert_rejected(self.verify())

    def test_unsigned_xml_tail_is_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes() + b'<!-- unsigned tail -->\n')
        self.assert_rejected(self.verify())

    def test_trailing_footer_whitespace_is_harmless(self):
        self.feed.write_bytes(self.feed.read_bytes() + b' \t\r\n')
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_archive_length_inside_validly_signed_feed_is_checked(self):
        self.make_fixture('archive-length')
        self.assert_rejected(self.verify())

    def test_archive_signature_and_unique_enclosure_are_required(self):
        for mode in ['missing-archive-signature', 'duplicate-enclosure']:
            with self.subTest(mode=mode):
                self.make_fixture(mode)
                self.assert_rejected(self.verify())

    def test_signed_doctype_is_rejected_without_resolving_entities(self):
        self.make_fixture('doctype')
        self.assert_rejected(self.verify())

    def test_invalid_utf8_cannot_be_normalized_into_a_valid_signature(self):
        self.make_fixture('replacement-character')
        # Lossy UTF-8 decoding maps both byte sequences to U+FFFD, but the
        # original signed bytes and original content length are different.
        data = self.feed.read_bytes()
        self.assertIn(b'\xef\xbf\xbd', data)
        self.feed.write_bytes(data.replace(b'\xef\xbf\xbd', b'\xff', 1))
        self.assert_rejected(self.verify())


if __name__ == '__main__':
    unittest.main()

"""Synthetic app/framework fixtures for release ZIP semantics."""
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'release_archive.py'
SPEC = importlib.util.spec_from_file_location('release_archive', SCRIPT)
archive_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive_helper)


class ReleaseArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / 'CmdTabo.app'
        self.framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        self.archive = self.root / 'release.zip'
        self.write('Contents/MacOS/CmdTabo', executable=True)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, executable=False):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'innocuous executable fixture' if executable else b'innocuous')
        path.chmod(0o751 if executable else 0o600)
        return path

    def link(self, relative, target):
        path = self.framework / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return path

    def test_preserves_framework_aliases_nested_executables_and_deterministic_metadata(self):
        prefix = 'Contents/Frameworks/Sparkle.framework/'
        for name in ['Sparkle', 'Updater.app/Contents/MacOS/Updater',
                     'XPCServices/Downloader.xpc/Contents/MacOS/Downloader']:
            self.write(prefix + 'Versions/B/' + name, executable=True)
        self.write(prefix + 'Versions/B/Resources/Info.plist')
        self.link('Versions/Current', 'B')
        self.link('Sparkle', 'Versions/Current/Sparkle')
        self.link('Resources', 'Versions/Current/Resources')
        digest = archive_helper.archive_app(self.app, self.archive)
        first = self.archive.read_bytes()
        self.assertEqual(digest, hashlib.sha256(first).hexdigest())
        self.assertEqual(archive_helper.archive_app(self.app, self.archive), digest)
        self.assertEqual(self.archive.read_bytes(), first)
        with zipfile.ZipFile(self.archive) as bundle:
            root = 'CmdTabo.app/' + prefix
            self.assertTrue(stat.S_ISLNK(bundle.getinfo(root + 'Versions/Current').external_attr >> 16))
            self.assertEqual(bundle.read(root + 'Sparkle'), b'Versions/Current/Sparkle')
            self.assertNotIn(root + 'Versions/Current/Sparkle', bundle.namelist())
            for name in ['Sparkle', 'Updater.app/Contents/MacOS/Updater',
                         'XPCServices/Downloader.xpc/Contents/MacOS/Downloader']:
                self.assertEqual(stat.S_IMODE(bundle.getinfo(root + 'Versions/B/' + name).external_attr >> 16), 0o755)
            self.assertEqual(stat.S_IMODE(bundle.getinfo(root + 'Versions/B/Resources/Info.plist').external_attr >> 16), 0o644)
            self.assertTrue(all(not item.extra and not item.comment and item.date_time == (1980, 1, 1, 0, 0, 0)
                                for item in bundle.infolist()))

    def test_rejects_absolute_and_relative_escaping_links_before_replacing_archive(self):
        for target in ['/outside', '../../../../../../outside']:
            with self.subTest(target=target):
                link = self.link('Versions/B/escape', target)
                self.archive.write_bytes(b'previous release')
                with self.assertRaises(ValueError):
                    archive_helper.archive_app(self.app, self.archive)
                self.assertEqual(self.archive.read_bytes(), b'previous release')
                link.unlink()

    def test_rejects_parent_escape_after_resolving_an_internal_directory_link(self):
        self.link('Versions/B/root', '../..')
        self.link('Versions/B/escape', 'root/../outside')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            archive_helper.archive_app(self.app, self.archive)

    def test_rejects_dangling_and_cyclic_links(self):
        link = self.link('Versions/B/missing', 'absent')
        with self.assertRaisesRegex(ValueError, 'dangling'):
            archive_helper.archive_app(self.app, self.archive)
        link.unlink()
        self.link('Versions/B/first', 'second')
        self.link('Versions/B/second', 'first')
        with self.assertRaisesRegex(ValueError, 'cyclic'):
            archive_helper.archive_app(self.app, self.archive)

    def test_rejects_links_outside_framework_even_when_target_is_inside_app(self):
        target = self.write('Contents/Resources/data.txt')
        (target.parent / 'alias').symlink_to('data.txt')
        with self.assertRaisesRegex(ValueError, 'outside the permitted framework'):
            archive_helper.archive_app(self.app, self.archive)

    def test_rejects_non_regular_files_and_symlink_app_root(self):
        fifo = self.app / 'Contents/pipe'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            archive_helper.archive_app(self.app, self.archive)
        fifo.unlink()
        alias = self.root / 'alias/CmdTabo.app'
        alias.parent.mkdir()
        alias.symlink_to(self.app)
        with self.assertRaisesRegex(ValueError, 'real CmdTabo.app'):
            archive_helper.archive_app(alias, self.archive)

    def test_cli_writes_checksum_of_final_zip_bytes(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.app), str(self.archive)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'SHA256SUMS.txt').read_text(),
                         hashlib.sha256(self.archive.read_bytes()).hexdigest() + '  release.zip\n')

    def test_validator_rejects_entries_nested_below_archive_symlinks(self):
        root = archive_helper.FRAMEWORK_ROOT
        entries = [(root + '/Versions/B/Resources/', stat.S_IFDIR | 0o755, b''),
                   (root + '/Resources', stat.S_IFLNK | 0o777, b'Versions/B/Resources'),
                   (root + '/Resources/payload', stat.S_IFREG | 0o644, b'')]
        with self.assertRaisesRegex(ValueError, 'non-directory'):
            archive_helper.validate_archive_entries(entries)

    def test_validator_rejects_ambiguous_paths_and_special_modes(self):
        for name, mode in [('CmdTabo.app/../outside', stat.S_IFREG),
                           ('CmdTabo.app/Contents//payload', stat.S_IFREG),
                           ('CmdTabo.app/Contents/payload', stat.S_IFIFO),
                           ('CmdTabo.app/Contents/payload/', stat.S_IFREG)]:
            with self.subTest(name=name, mode=mode), self.assertRaises(ValueError):
                archive_helper.validate_archive_entries([(name, mode, b'')])


if __name__ == '__main__':
    unittest.main()

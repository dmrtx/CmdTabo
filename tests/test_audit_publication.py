"""Synthetic publication fixtures; never use workstation or account data."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


AUDITOR = Path(__file__).resolve().parents[1] / 'scripts' / 'audit-publication.py'
SPEC = importlib.util.spec_from_file_location('audit_publication', AUDITOR)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class PublicationAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture' + '@' + 'users.noreply.github.com')
        self.private_name = 'synthetic' + '@' + 'example.invalid'

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(['git', '-C', str(self.root), *arguments], check=True, capture_output=True).stdout

    def add(self, name, contents='innocuous'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        self.git('add', '--', name)

    def run_audit(self, *arguments):
        return subprocess.run([sys.executable, str(AUDITOR), *arguments], cwd=self.root,
                              capture_output=True, text=True)

    def assert_redacted_failure(self, result, *private_values):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('[redacted path]', result.stdout)
        for value in private_values:
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_clean_index_and_archive(self):
        self.add('safe.txt')
        archive = self.archive(['CmdTabo.app/Contents/Resources/safe.txt'])
        result = self.run_audit('--archive', str(archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_index_filename_and_directory_names_are_redacted(self):
        for name in [self.private_name + '.txt', self.private_name + '/safe.txt']:
            self.add(name)
        self.assert_redacted_failure(self.run_audit(), self.private_name)

    def test_shared_blob_historical_renames_are_checked(self):
        self.add('safe.txt')
        self.git('commit', '-qm', 'Initial fixture')
        self.git('mv', 'safe.txt', self.private_name + '.txt')
        self.git('commit', '-qm', 'Renamed fixture')
        self.git('mv', self.private_name + '.txt', 'safe.txt')
        self.git('commit', '-qm', 'Restored fixture')
        self.assertEqual(self.run_audit().returncode, 0)
        self.assert_redacted_failure(self.run_audit('--history'), self.private_name)

    def test_deleted_historical_directory_and_newline_path(self):
        name = self.private_name + '/line\nbreak.txt'
        self.add(name)
        self.git('commit', '-qm', 'Directory fixture')
        self.git('rm', '--', name)
        self.add('safe.txt')
        self.git('commit', '-qm', 'Remove fixture')
        self.assert_redacted_failure(self.run_audit('--history'), self.private_name)

    def archive(self, names, metadata=False):
        path = self.root / 'fixture.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('CmdTabo.app/Contents/MacOS/CmdTabo', 'innocuous executable fixture')
            for name in names:
                entry = zipfile.ZipInfo(name)
                if metadata:
                    entry.comment = b'fixture'
                archive.writestr(entry, 'innocuous')
        return path

    def test_archive_files_and_empty_directories_are_checked(self):
        for name in ['CmdTabo.app/Contents/Resources/' + self.private_name + '.txt',
                     'CmdTabo.app/Contents/Resources/' + self.private_name + '/']:
            archive = self.archive([name])
            self.assert_redacted_failure(self.run_audit('--archive', str(archive)), self.private_name)

    def test_unexpected_file_and_metadata_diagnostics_redact_paths(self):
        archive = self.archive(['CmdTabo.app/' + self.private_name + '.txt'], metadata=True)
        result = self.run_audit('--archive', str(archive))
        self.assert_redacted_failure(result, self.private_name)
        self.assertIn('unexpected bundled file', result.stdout)
        self.assertIn('extended ZIP metadata', result.stdout)

    def test_content_detection_still_redacts_values(self):
        self.add('safe.txt', self.private_name)
        result = self.run_audit()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(self.private_name, result.stdout + result.stderr)

    def test_local_identity_and_network_address_in_names(self):
        identity = 'synthetic-identity'
        address = '.'.join(['192', '0', '2', '42'])
        hints = [audit.re.compile(audit.re.escape(identity))]
        self.assertEqual(audit.safe_label('index:' + identity + '/safe.txt', hints), 'index:[redacted path]')
        self.add(address + '.txt')
        self.assert_redacted_failure(self.run_audit(), address)

    def test_control_characters_cannot_forge_diagnostics(self):
        self.assertEqual(audit.safe_label('index:line\nbreak\x1b.txt', []), 'index:line?break?.txt')

    def test_invalid_archive_error_does_not_print_sensitive_path(self):
        path = self.root / (self.private_name + '.zip')
        path.write_text('invalid ZIP')
        result = self.run_audit('--archive', str(path))
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(self.private_name, result.stdout + result.stderr)

    def test_history_allows_only_public_handle_and_noreply_metadata(self):
        self.add('safe.txt')
        self.git('commit', '-qm', 'Public fixture')
        self.assertEqual(self.run_audit('--history').returncode, 0)
        self.git('config', 'user.email', self.private_name)
        self.add('another.txt')
        self.git('commit', '-qm', 'Private metadata fixture')
        result = self.run_audit('--history')
        self.assertEqual(result.returncode, 1)
        self.assertIn('non-public author or committer identity', result.stdout)
        self.assertNotIn(self.private_name, result.stdout + result.stderr)

    def test_full_name_is_not_permitted_even_with_noreply_address(self):
        self.assertFalse(audit.public_identity('Synthetic Full Name', 'fixture' + '@' + 'users.noreply.github.com'))
        self.assertTrue(audit.public_identity('Fixture', '123+fixture' + '@' + 'users.noreply.github.com'))

    def commit_fixture(self):
        self.add('safe.txt')
        self.git('commit', '-qm', 'Public fixture')

    def assert_private_tag_failure(self, result, *values):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('tag:', result.stdout)
        for value in values:
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_history_accepts_public_annotated_and_lightweight_tags(self):
        self.commit_fixture()
        self.git('tag', '-a', 'v-public', '-m', 'Public release')
        self.git('tag', 'v-lightweight')
        result = self.run_audit('--history')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_history_rejects_private_tagger_without_printing_identity(self):
        self.commit_fixture()
        self.git('config', 'user.email', self.private_name)
        self.git('tag', '-a', 'v-private', '-m', 'Release')
        self.assert_private_tag_failure(self.run_audit('--history'), self.private_name)

    def test_history_rejects_full_name_tagger_with_noreply(self):
        self.commit_fixture()
        self.git('config', 'user.name', 'Synthetic Full Name')
        self.git('tag', '-a', 'v-private', '-m', 'Release')
        self.assert_private_tag_failure(self.run_audit('--history'), 'Synthetic Full Name')

    def test_history_rejects_private_tag_message_and_name(self):
        self.commit_fixture()
        self.git('tag', '-a', self.private_name, '-m', 'Contact: ' + self.private_name)
        self.assert_private_tag_failure(self.run_audit('--history'), self.private_name)

    def test_history_rejects_private_tag_name_with_public_message(self):
        self.commit_fixture()
        self.git('tag', '-a', self.private_name, '-m', 'Public release')
        self.assert_private_tag_failure(self.run_audit('--history'), self.private_name)

    def test_history_checks_tag_ref_aliases_and_lightweight_names(self):
        self.commit_fixture()
        self.git('tag', '-a', 'v-public', '-m', 'Public release')
        target = self.git('rev-parse', 'v-public').decode().strip()
        self.git('update-ref', 'refs/tags/' + self.private_name, target)
        self.assert_redacted_failure(self.run_audit('--history'), self.private_name)
        self.git('tag', '-d', self.private_name)
        self.git('tag', self.private_name)
        self.assert_redacted_failure(self.run_audit('--history'), self.private_name)

    def test_history_checks_additional_tag_headers(self):
        self.commit_fixture()
        target = self.git('rev-parse', 'HEAD').decode().strip()
        raw = (f'object {target}\ntype commit\ntag v-fixture\n'
               'tagger Fixture <fixture' + '@' + 'users.noreply.github.com> 1 +0000\n'
               'extra ' + self.private_name + '\n\nPublic release\n')
        object_id = subprocess.run(['git', '-C', str(self.root), 'hash-object', '-w', '-t', 'tag', '--stdin'],
                                   input=raw.encode(), check=True, capture_output=True).stdout.decode().strip()
        self.git('update-ref', 'refs/tags/v-fixture', object_id)
        self.assert_private_tag_failure(self.run_audit('--history'), self.private_name)

    def test_history_checks_inner_tag_reachable_only_through_outer_tag(self):
        self.commit_fixture()
        self.git('tag', '-a', 'v-inner', '-m', 'Contact: ' + self.private_name)
        self.git('tag', '-a', 'v-outer', 'v-inner', '-m', 'Public wrapper')
        self.git('tag', '-d', 'v-inner')
        self.assert_private_tag_failure(self.run_audit('--history'), self.private_name)


if __name__ == '__main__':
    unittest.main()

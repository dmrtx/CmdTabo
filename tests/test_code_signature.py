"""Public-only regression tests for persistent code-signing requirements."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/verify-code-signature.py'
SPEC = importlib.util.spec_from_file_location('verify_code_signature', SCRIPT)
SIGNATURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNATURE)
IDENTIFIER = 'local.cmdtabo.switcher'
REQUIREMENT = f'designated => identifier "{IDENTIFIER}" and certificate leaf = H"{SIGNATURE.SHA1.lower()}"'


class CodeSignatureTests(unittest.TestCase):
    def test_exact_main_requirement_accepts_codesign_output_and_hex_case(self):
        for pin in [SIGNATURE.SHA1, SIGNATURE.SHA1.lower()]:
            output = REQUIREMENT.replace(SIGNATURE.SHA1.lower(), pin)
            SIGNATURE.verify_requirement(output + '\n', IDENTIFIER, main=True)

    def test_added_alternatives_cannot_weaken_the_pin(self):
        for tail in [' or true', f' or identifier "{IDENTIFIER}"', ' or anchor apple', '\nor true']:
            with self.subTest(tail=tail), self.assertRaises(ValueError):
                SIGNATURE.verify_requirement(REQUIREMENT + tail, IDENTIFIER, main=True)

    def test_other_certificates_and_identifiers_are_rejected(self):
        for output in [REQUIREMENT.replace(SIGNATURE.SHA1.lower(), '0' * 40),
                       REQUIREMENT.replace(IDENTIFIER, 'local.cmdtabo.other'),
                       REQUIREMENT.replace(IDENTIFIER, IDENTIFIER.upper())]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                SIGNATURE.verify_requirement(output, IDENTIFIER, main=True)

    def test_cdhash_or_bundle_identifier_alone_is_not_stable_identity(self):
        for output in [f'designated => identifier "{IDENTIFIER}"',
                       'designated => cdhash H"' + '0' * 40 + '"']:
            with self.subTest(output=output), self.assertRaises(ValueError):
                SIGNATURE.verify_requirement(output, IDENTIFIER, main=True)

    def test_missing_or_duplicate_requirements_are_rejected(self):
        for output in ['', REQUIREMENT + '\n' + REQUIREMENT]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                SIGNATURE.verify_requirement(output, IDENTIFIER, main=True)

    def test_nested_root_and_unquoted_helper_identifiers_remain_strong(self):
        output = f'designated => identifier Autoupdate and certificate root = H"{SIGNATURE.SHA1.lower()}"'
        SIGNATURE.verify_requirement(output, 'Autoupdate')
        with self.assertRaises(ValueError):
            SIGNATURE.verify_requirement(output + ' or true', 'Autoupdate')

    def test_main_requirement_must_use_exact_leaf(self):
        with self.assertRaises(ValueError):
            SIGNATURE.verify_requirement(REQUIREMENT.replace('certificate leaf', 'certificate root'), IDENTIFIER, main=True)


if __name__ == '__main__':
    unittest.main()

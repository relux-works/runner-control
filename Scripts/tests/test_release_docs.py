"""RELEASING.md states the exact values the release scripts enforce.

Each test derives the expected value from the enforcing code (not from the
docs) and requires the docs to name it, so doc drift fails the suite. The
run/attempt bound test additionally drives release_metadata.prepare at the
documented limit in both directions, tying docs to code behaviorally.
"""
import base64
import copy
import importlib.util
from pathlib import Path
import re
import unittest

REPO = Path(__file__).parents[2]
DOCS = (REPO / 'RELEASING.md').read_text()

spec = importlib.util.spec_from_file_location('metadata', REPO / 'Scripts' / 'release_metadata.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def _config():
    return {'marketing_version': '1.1.0', 'bundle_id': 'works.relux.runnercontrol',
            'team_id': '262RZ595FP', 'macos': {'info_plist': {
                'SUFeedURL': m.FEED, 'SUPublicEDKey': base64.b64encode(bytes(32)).decode()}}}


class ReleaseDocsTests(unittest.TestCase):
    def test_docs_name_sparkle_tool_pin(self):
        tools = (REPO / 'Scripts' / 'sparkle-tools.sh').read_text()
        version = re.search(r'^version=(\S+)$', tools, re.M).group(1)
        checksum = re.search(r'^checksum=(\S+)$', tools, re.M).group(1)
        self.assertIn(version, DOCS)
        self.assertIn(checksum, DOCS)

    def test_docs_name_signing_team_profile_and_account(self):
        release = (REPO / 'Scripts' / 'release.sh').read_text()
        preflight = (REPO / 'Scripts' / 'release-preflight.sh').read_text()
        teams = set(re.findall(r'DEVELOPMENT_TEAM=(\w+)', release))
        self.assertTrue(teams)
        for team in teams:
            self.assertIn(team, DOCS)
        profile = re.search(r'NOTARY_PROFILE:-([^}]+)\}', preflight).group(1)
        self.assertIn(profile, DOCS)
        accounts = set(re.findall(r'--account (\S+)', release + preflight))
        self.assertTrue(accounts)
        for account in accounts:
            self.assertIn(account, DOCS)

    def test_docs_name_toolchain_pins(self):
        workflow = (REPO / '.github' / 'workflows' / 'release.yml').read_text()
        go = re.search(r"go-version: '([^']+)'", workflow).group(1)
        generator = re.search(r'git checkout --detach (\S+)', workflow).group(1)
        self.assertIn(go, DOCS)
        self.assertIn(generator, DOCS)
        self.assertIn('Tuist 4.9.0', DOCS)

    def test_documented_run_attempt_bounds_match_code(self):
        max_run = int(re.search(r'run 1\.\.(\d+)', DOCS).group(1))
        max_attempt = int(re.search(r'attempt 1\.\.(\d+)', DOCS).group(1))
        got = m.prepare(copy.deepcopy(_config()), 'v1.1.0', max_run, max_attempt)['project_version']
        self.assertEqual(got, f'{100 + max_run}.{max_attempt}')
        with self.assertRaises(ValueError):
            m.prepare(copy.deepcopy(_config()), 'v1.1.0', max_run + 1, 1)
        with self.assertRaises(ValueError):
            m.prepare(copy.deepcopy(_config()), 'v1.1.0', 1, max_attempt + 1)

    def test_docs_state_notarization_gates_and_diagnostic_handling(self):
        release = (REPO / 'Scripts' / 'release.sh').read_text()
        self.assertGreaterEqual(len(re.findall(r'^notarize ', release, re.M)), 2,
                                'release.sh must notarize app ZIP and DMG separately')
        self.assertIn("!= 'Accepted'", release)
        self.assertGreaterEqual(len(re.findall(r'stapler validate', release)), 2,
                                'each artifact must pass staple validation')
        diagnostic = '6d537548-8c24-48ea-89b5-7ebb2dc959d5'
        self.assertIn(diagnostic, DOCS)
        for phrase in ('its own `Accepted`', 'stapler staple', 'Do not duplicate',
                       'not a release artifact', 'is authorized',
                       'notarytool info', 'read-only', 'v1.2.0'):
            self.assertIn(phrase, DOCS, phrase)

    def test_docs_contain_no_secret_material(self):
        for name in ('RELEASING.md', 'README.md'):
            text = (REPO / name).read_text()
            self.assertNotRegex(text, r'BEGIN [A-Z ]*PRIVATE')
            self.assertNotRegex(text, r'BEGIN CERTIFICATE')
            self.assertNotRegex(text, r'\b[A-F0-9]{40}\b')


if __name__ == '__main__':
    unittest.main()

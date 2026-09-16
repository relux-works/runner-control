"""Drive Scripts/release-preflight.sh with stubbed macOS tools.

Each test builds an isolated repo root (preflight + sparkle-tools scripts,
minimal ios-app-manager.json, stub Sparkle tools so no download happens) and
a stub bin dir shadowing xcrun/security. Real python3/bash/grep run from PATH.
No credentials enter the fixtures.
"""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).parents[2]
PUBKEY = base64.b64encode(bytes(32)).decode()
WRONG_PUBKEY = base64.b64encode(bytes(range(32))).decode()
TEAM_LINE = '  3) 267D90FC976A48CF830BE7F41AE612999E025054 "Developer ID Application: Relux Works, LLC (262RZ595FP)"'
OTHER_LINES = ('  1) 7FB8D981868F2637B75DFD098A1F87E0CC11158D "Apple Development: Ivan Oparin (45W9YW7M6V)"\n'
               '  4) C8448515B5871071F90EB0168A79DCD35E7CA9FE "Developer ID Application: SKL VC DMCC (4Y4UJAT8QR)"')


def write_exe(path, content):
    path.write_text(content)
    path.chmod(0o755)


class PreflightHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        for name in ('release-preflight.sh', 'sparkle-tools.sh'):
            shutil.copy(REPO / 'Scripts' / name, scripts / name)
        (root / 'ios-app-manager.json').write_text(json.dumps(
            {'macos': {'info_plist': {'SUPublicEDKey': PUBKEY}}}))
        sparkle_bin = root / '.temp' / 'tools' / 'Sparkle-2.10.0' / 'bin'
        sparkle_bin.mkdir(parents=True)
        write_exe(sparkle_bin / 'generate_appcast', '#!/bin/sh\nexit 0\n')
        self.sparkle_bin = sparkle_bin
        self.bindir = root / 'bin'
        self.bindir.mkdir()
        for tool in ('xcodebuild', 'codesign', 'hdiutil', 'tuist', 'gh'):
            write_exe(self.bindir / tool, '#!/bin/sh\nexit 0\n')
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def run_preflight(self, security_out, xcrun_script, sparkle_key=PUBKEY, profile=None,
                      security_exit=0, security_err=''):
        stub = '#!/bin/sh\n'
        if security_err:
            stub += 'echo ' + shlex.quote(security_err) + ' >&2\n'
        if security_out:
            stub += 'cat <<\'EOF\'\n' + security_out + '\nEOF\n'
        stub += 'exit ' + str(security_exit) + '\n'
        write_exe(self.bindir / 'security', stub)
        write_exe(self.bindir / 'xcrun', xcrun_script)
        write_exe(self.sparkle_bin / 'generate_keys', '#!/bin/sh\necho ' + sparkle_key + '\n')
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        if profile is None:
            env.pop('NOTARY_PROFILE', None)
        else:
            env['NOTARY_PROFILE'] = profile
        return subprocess.run(['bash', str(self.root / 'Scripts' / 'release-preflight.sh')],
                              capture_output=True, text=True, timeout=60, env=env, cwd=self.tmp.name)


class ReleasePreflightTests(PreflightHarness):
    def test_preflight_passes_with_valid_credentials(self):
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, '#!/bin/sh\nexit 0\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Release prerequisites verified', r.stdout)
        self.assertIn('RunnerControl-notary', r.stdout)

    def test_locked_keychain_fails_with_unlock_guidance(self):
        stub = ('#!/bin/sh\necho \'Error: keychainLocked(keychainName: "default", keychainURL: nil)'
                ' Use Keychain Access or the `security unlock-keychain` command line tool'
                ' to unlock the default keychain.\' >&2\nexit 1\n')
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, stub)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('locked', r.stderr)
        self.assertIn('workflow_dispatch', r.stderr)
        self.assertIn('RunnerControl-notary', r.stderr)

    def test_missing_profile_names_profile_without_locked_guidance(self):
        stub = ('#!/bin/sh\necho "Error: No Keychain password item found for profile: Custom-Profile-9" >&2\n'
                'echo "Run \'notarytool store-credentials\' to create another credential profile." >&2\nexit 1\n')
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, stub, profile='Custom-Profile-9')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Custom-Profile-9', r.stderr)
        self.assertIn('store-credentials', r.stderr)
        self.assertIn('missing from the login keychain', r.stderr)
        self.assertNotIn('locked', r.stderr)

    def test_missing_identity_rejected(self):
        r = self.run_preflight(OTHER_LINES, '#!/bin/sh\nexit 0\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Missing Developer ID Application identity', r.stderr)

    def test_multiple_team_identities_rejected(self):
        second = TEAM_LINE.replace('267D90FC976A48CF830BE7F41AE612999E025054',
                                   'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA').replace('  3)', '  5)')
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE + '\n' + second, '#!/bin/sh\nexit 0\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Multiple Developer ID Application identities', r.stderr)

    def test_sparkle_key_mismatch_rejected(self):
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, '#!/bin/sh\nexit 0\n', sparkle_key=WRONG_PUBKEY)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Sparkle signing key', r.stderr)

    def test_failed_identity_read_with_empty_output_is_unknown_not_missing(self):
        r = self.run_preflight('', '#!/bin/sh\nexit 0\n',
                               security_exit=42, security_err='security: read failed')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Could not read signing identities', r.stderr)
        self.assertNotIn('Missing Developer ID Application identity', r.stderr)
        self.assertNotIn('Release prerequisites verified', r.stdout)

    def test_failed_identity_read_with_partial_output_is_not_verified(self):
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, '#!/bin/sh\nexit 0\n',
                               security_exit=42, security_err='security: read failed')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Could not read signing identities', r.stderr)
        self.assertNotIn('Release prerequisites verified', r.stdout)

    def test_apple_development_same_team_rejected(self):
        same_team_dev = ('  1) 7FB8D981868F2637B75DFD098A1F87E0CC11158D '
                         '"Apple Development: Ivan Oparin (262RZ595FP)"')
        other_team_devid = ('  4) C8448515B5871071F90EB0168A79DCD35E7CA9FE '
                            '"Developer ID Application: SKL VC DMCC (4Y4UJAT8QR)"')
        r = self.run_preflight(same_team_dev + '\n' + other_team_devid, '#!/bin/sh\nexit 0\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Missing Developer ID Application identity', r.stderr)
        self.assertNotIn('Release prerequisites verified', r.stdout)

    def test_missing_tool_rejected(self):
        (self.bindir / 'tuist').unlink()
        write_exe(self.bindir / 'security', '#!/bin/sh\nexit 0\n')
        write_exe(self.bindir / 'xcrun', '#!/bin/sh\nexit 0\n')
        env = dict(os.environ)
        env['PATH'] = str(self.bindir)
        bash = shutil.which('bash')
        self.assertTrue(bash, 'absolute bash path required for the isolated-PATH probe')
        r = subprocess.run([bash, str(self.root / 'Scripts' / 'release-preflight.sh')],
                           capture_output=True, text=True, timeout=60, env=env, cwd=self.tmp.name)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('Missing release tool: tuist', r.stderr)
        self.assertNotIn('Release prerequisites verified', r.stdout)

    def test_unknown_notary_error_reports_profile(self):
        stub = ('#!/bin/sh\necho "Error: HTTP 500 from the Apple notary service" >&2\n'
                'echo "Try again later." >&2\nexit 1\n')
        r = self.run_preflight(OTHER_LINES + '\n' + TEAM_LINE, stub)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('notarytool history failed', r.stderr)
        self.assertIn('RunnerControl-notary', r.stderr)
        self.assertIn('HTTP 500', r.stderr)
        self.assertNotIn('locked', r.stderr)
        self.assertNotIn('missing from the login keychain', r.stderr)


if __name__ == '__main__':
    unittest.main()

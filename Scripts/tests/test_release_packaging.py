"""Drive the real Scripts/release.sh end to end with stubbed macOS tools.

Each test builds an isolated repo root (real release.sh, release-preflight.sh,
release_metadata.py, sparkle-tools.sh; fixture ios-app-manager.json for the
coordinator-approved v1.2.0 target) and a stub bin dir shadowing security,
xcrun, xcodebuild, codesign, ditto, hdiutil, spctl, tuist, gh plus the
generator binary. The Sparkle bin dir is pre-created so no download happens.
No credentials enter the fixtures; no Apple submission or publication occurs.

The DMG-signing gate is proven behaviorally: the codesign stub records every
invocation, and tests assert the exact resolved team identity reaches
`codesign --sign`, on first attempt and on retry, and that zero/multiple
identities prevent all packaging and workflow output. Refusal coverage extends
to tag/marketing mismatch, out-of-range run numbers, notary rejection, a wrong
codesign team, appcast tampering, and an unresolvable identity hash that passes
preflight but must fail DMG signing; late refusals assert no SHA256SUMS and no
dist= workflow output escape.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).parents[2]
TAG = 'v1.2.0'
TEAM = '262RZ595FP'
EXPECTED_SHA = '267D90FC976A48CF830BE7F41AE612999E025054'
PUBKEY = base64.b64encode(bytes(32)).decode()
TEAM_LINE = f'  3) {EXPECTED_SHA} "Developer ID Application: Relux Works, LLC ({TEAM})"'
OTHER_LINES = ('  1) 7FB8D981868F2637B75DFD098A1F87E0CC11158D "Apple Development: Ivan Oparin (45W9YW7M6V)"\n'
               '  4) C8448515B5871071F90EB0168A79DCD35E7CA9FE "Developer ID Application: SKL VC DMCC (4Y4UJAT8QR)"')
VALID_OUTPUT = OTHER_LINES + '\n' + TEAM_LINE

GENERATE_APPCAST = '''#!/usr/bin/env python3
import base64, json, os, sys
args = sys.argv[1:]
distdir = args[-1]
prefix = args[args.index('--download-url-prefix') + 1]
tag = os.environ['RELEASE_TAG']
root = os.environ['FIXTURE_ROOT']
build = json.load(open(os.path.join(root, 'ios-app-manager.json')))['project_version']
if os.environ.get('APPCAST_TAMPER') == '1':
    build = '0.0-tampered'
size = os.path.getsize(os.path.join(distdir, 'RunnerControl.dmg'))
sig = base64.b64encode(bytes(64)).decode()
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<item>
<title>Runner Control {tag}</title>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{tag[1:]}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{prefix}RunnerControl.dmg" length="{size}" type="application/octet-stream" sparkle:edSignature="{sig}" />
</item>
</channel>
</rss>
"""
open(os.path.join(distdir, 'appcast.xml'), 'w').write(xml)
'''

XCODEBUILD_STUB = '''#!/bin/bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-archivePath" ]; then mkdir -p "$a"; fi
  if [ "$prev" = "-exportPath" ]; then
    mkdir -p "$a/RunnerControl.app"
    printf 'fixture' > "$a/RunnerControl.app/RunnerControl"
  fi
  prev="$a"
done
exit 0
'''

XCRUN_STUB = '''#!/bin/bash
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  printf '{"status":"%s","id":"00000000-0000-0000-0000-000000000000"}\\n' "${NOTARY_STATUS:-Accepted}"
fi
exit 0
'''

CODESIGN_STUB = '''#!/bin/bash
if [ "${1:-}" = "-dvv" ]; then
  team="${CODESIGN_TEAM:-262RZ595FP}"
  echo "Executable=${2:-}"
  echo "Identifier=works.relux.runnercontrol"
  echo "TeamIdentifier=$team"
  echo "Authority=Developer ID Application: Relux Works, LLC ($team)"
  exit 0
fi
printf '%s\\n' "$*" >> "$CODESIGN_LOG"
exit 0
'''

DITTO_STUB = '''#!/bin/bash
dest="${@: -1}"
if [ "${1:-}" = "-c" ]; then : > "$dest"; else mkdir -p "$dest"; fi
exit 0
'''

HDIUTIL_STUB = '''#!/bin/bash
printf 'fixture-dmg' > "${@: -1}"
exit 0
'''

SWIFT_STUB = '''#!/bin/bash
# Fake `swift build`: materialize a dummy CLI product at the real
# multi-arch layout build-cli.sh expects.
scratch=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--scratch-path" ]; then scratch="$arg"; fi
  prev="$arg"
done
if [ -n "$scratch" ]; then
  mkdir -p "$scratch/apple/Products/Release"
  printf '#!/bin/sh\\nexit 0\\n' > "$scratch/apple/Products/Release/runner-control"
  chmod +x "$scratch/apple/Products/Release/runner-control"
fi
exit 0
'''


def write_exe(path, content):
    path.write_text(content)
    path.chmod(0o755)


class ReleasePackagingHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        scripts = root / 'Scripts'
        scripts.mkdir()
        for name in ('release.sh', 'release-preflight.sh', 'release_metadata.py',
                     'sparkle-tools.sh', 'build-cli.sh'):
            shutil.copy(REPO / 'Scripts' / name, scripts / name)
        (root / 'ios-app-manager.json').write_text(json.dumps({
            'bundle_id': 'works.relux.runnercontrol',
            'team_id': TEAM,
            'marketing_version': TAG[1:],
            'macos': {'info_plist': {
                'SUFeedURL': 'https://github.com/relux-works/runner-control/releases/latest/download/appcast.xml',
                'SUPublicEDKey': PUBKEY}}}))
        sparkle_bin = root / '.temp' / 'tools' / 'Sparkle-2.10.0' / 'bin'
        sparkle_bin.mkdir(parents=True)
        write_exe(sparkle_bin / 'generate_appcast', GENERATE_APPCAST)
        write_exe(sparkle_bin / 'generate_keys', '#!/bin/sh\necho ' + PUBKEY + '\n')
        bindir = root / 'bin'
        bindir.mkdir()
        write_exe(bindir / 'xcodebuild', XCODEBUILD_STUB)
        write_exe(bindir / 'xcrun', XCRUN_STUB)
        write_exe(bindir / 'codesign', CODESIGN_STUB)
        write_exe(bindir / 'ditto', DITTO_STUB)
        write_exe(bindir / 'hdiutil', HDIUTIL_STUB)
        write_exe(bindir / 'swift', SWIFT_STUB)
        for tool in ('spctl', 'tuist', 'gh', 'ios-app-manager'):
            write_exe(bindir / tool, '#!/bin/bash\nexit 0\n')
        self.root = root
        self.bindir = bindir
        self.codesign_log = root / 'codesign.log'
        self.github_output = root / 'github-output.txt'

    def tearDown(self):
        self.tmp.cleanup()

    def run_release(self, security_out, attempt=1, run_number=101, tag=TAG,
                    notary_status='Accepted', codesign_team=TEAM, tamper_appcast=False):
        if security_out:
            stub = '#!/bin/sh\ncat <<\'EOF\'\n' + security_out + '\nEOF\n'
        else:
            stub = '#!/bin/sh\n'
        write_exe(self.bindir / 'security', stub)
        env = dict(os.environ)
        env['PATH'] = str(self.bindir) + os.pathsep + env['PATH']
        env['RELEASE_TAG'] = tag
        env['GITHUB_RUN_NUMBER'] = str(run_number)
        env['GITHUB_RUN_ATTEMPT'] = str(attempt)
        env['IOS_APP_MANAGER'] = str(self.bindir / 'ios-app-manager')
        env['GITHUB_OUTPUT'] = str(self.github_output)
        env['CODESIGN_LOG'] = str(self.codesign_log)
        env['FIXTURE_ROOT'] = str(self.root)
        env['NOTARY_STATUS'] = notary_status
        env['CODESIGN_TEAM'] = codesign_team
        env['APPCAST_TAMPER'] = '1' if tamper_appcast else '0'
        env.pop('NOTARY_PROFILE', None)
        return subprocess.run(['bash', str(self.root / 'Scripts' / 'release.sh')],
                              capture_output=True, text=True, timeout=180,
                              env=env, cwd=self.tmp.name)

    def dist_of(self):
        for line in self.github_output.read_text().splitlines():
            if line.startswith('dist='):
                return Path(line[len('dist='):])
        self.fail('release wrote no dist= workflow output')

    def assert_no_packaging_or_output(self, result):
        self.assertNotEqual(result.returncode, 0)
        if self.codesign_log.exists():
            self.assertNotIn('--sign ', self.codesign_log.read_text())
        if self.github_output.exists():
            self.assertNotIn('dist=', self.github_output.read_text())
        packaged = [p for p in (self.root / '.temp').glob('release-*')
                    if p.name != 'tools']
        self.assertEqual(packaged, [])

    def assert_no_publish_output(self, result):
        """Late refusal: packaging may exist, but nothing publishable escapes."""
        self.assertNotEqual(result.returncode, 0)
        if self.github_output.exists():
            self.assertNotIn('dist=', self.github_output.read_text())
        sums = list((self.root / '.temp').glob('release-*/dist/SHA256SUMS'))
        self.assertEqual(sums, [])

    def assert_dmg_never_signed(self):
        """The DMG is signed only on the success path. The embedded CLI is
        legitimately signed earlier (before notarization), so a blanket
        no-sign assertion would be wrong."""
        if not self.codesign_log.exists():
            return
        signed = [line for line in self.codesign_log.read_text().splitlines()
                  if '--sign ' in line and 'RunnerControl.dmg' in line]
        self.assertEqual(signed, [])


class ReleasePackagingTests(ReleasePackagingHarness):
    def test_release_signs_dmg_with_resolved_team_identity(self):
        r = self.run_release(VALID_OUTPUT, attempt=1)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        self.assertIn(f'--sign {EXPECTED_SHA}', self.codesign_log.read_text())
        dist = self.dist_of()
        for name in ('RunnerControl.dmg', 'appcast.xml', 'SHA256SUMS'):
            self.assertTrue((dist / name).exists(), name)

    def test_retry_attempt_signs_with_resolved_team_identity(self):
        r = self.run_release(VALID_OUTPUT, attempt=2)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        self.assertIn(f'--sign {EXPECTED_SHA}', self.codesign_log.read_text())
        dist = self.dist_of()
        for name in ('RunnerControl.dmg', 'appcast.xml', 'SHA256SUMS'):
            self.assertTrue((dist / name).exists(), name)

    def test_release_embeds_signed_cli(self):
        r = self.run_release(VALID_OUTPUT, attempt=1)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        embedded = list(self.root.glob('.temp/**/RunnerControl.app/Contents/Helpers/runner-control'))
        self.assertTrue(embedded, 'CLI missing from exported app bundle')
        log = self.codesign_log.read_text()
        cli_signs = [line for line in log.splitlines()
                     if '--sign ' in line and line.rstrip().endswith('runner-control')]
        self.assertTrue(cli_signs, 'CLI binary never signed')

    def test_zero_identities_prevents_packaging_and_output(self):
        r = self.run_release(OTHER_LINES, attempt=1)
        self.assert_no_packaging_or_output(r)

    def test_multiple_identities_prevents_packaging_and_output(self):
        second = TEAM_LINE.replace(EXPECTED_SHA, 'A' * 40).replace('  3)', '  5)')
        r = self.run_release(VALID_OUTPUT + '\n' + second, attempt=1)
        self.assert_no_packaging_or_output(r)

    def test_tag_marketing_mismatch_prevents_packaging(self):
        r = self.run_release(VALID_OUTPUT, attempt=1, tag='v9.9.9')
        self.assert_no_packaging_or_output(r)
        self.assertIn('marketing_version', r.stderr)

    def test_invalid_run_number_prevents_packaging(self):
        r = self.run_release(VALID_OUTPUT, attempt=1, run_number=0)
        self.assert_no_packaging_or_output(r)
        self.assertIn('run/attempt', r.stderr)

    def test_boundary_run_attempt_accepted(self):
        r = self.run_release(VALID_OUTPUT, attempt=99, run_number=9899)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        self.assertIn(f'--sign {EXPECTED_SHA}', self.codesign_log.read_text())
        dist = self.dist_of()
        for name in ('RunnerControl.dmg', 'appcast.xml', 'SHA256SUMS'):
            self.assertTrue((dist / name).exists(), name)

    def test_notarization_rejection_prevents_publish(self):
        r = self.run_release(VALID_OUTPUT, attempt=1, notary_status='Rejected')
        self.assert_no_publish_output(r)
        self.assertIn('did not accept', r.stderr)
        self.assert_dmg_never_signed()

    def test_codesign_team_mismatch_prevents_packaging(self):
        r = self.run_release(VALID_OUTPUT, attempt=1, codesign_team='OTHERTEAM1')
        self.assert_no_publish_output(r)
        self.assert_dmg_never_signed()

    def test_appcast_tamper_prevents_publish(self):
        r = self.run_release(VALID_OUTPUT, attempt=1, tamper_appcast=True)
        self.assert_no_publish_output(r)
        self.assertIn('Appcast build does not match', r.stderr)

    def test_malformed_identity_hash_prevents_signing(self):
        malformed = TEAM_LINE.replace(EXPECTED_SHA, 'X' * 40)
        r = self.run_release(OTHER_LINES + '\n' + malformed, attempt=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('No Developer ID Application identity', r.stderr)
        if self.codesign_log.exists():
            self.assertNotIn('--sign ', self.codesign_log.read_text())
        if self.github_output.exists():
            self.assertNotIn('dist=', self.github_output.read_text())


if __name__ == '__main__':
    unittest.main()

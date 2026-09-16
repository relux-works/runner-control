import base64
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).parents[1] / 'release_metadata.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.config = {'marketing_version': '1.1.0', 'bundle_id': 'works.relux.runnercontrol',
                       'team_id': '262RZ595FP', 'macos': {'info_plist': {
                           'SUFeedURL': m.FEED, 'SUPublicEDKey': base64.b64encode(bytes(32)).decode()}}}
    def test_builds_increase_between_attempts_and_runs(self):
        values = [m.prepare(copy.deepcopy(self.config), 'v1.1.0', r, a)['project_version']
                  for r, a in [(1, 1), (1, 2), (2, 1)]]
        self.assertEqual(values, ['101.1', '101.2', '102.1'])
    def test_rejects_wrong_tag_or_identity(self):
        for tag in ['v1.0.0', 'main', 'v1.1.0;echo', 'v1.2', 'v1.2.3.4', '1.1.0', 'v1.1.0 ']:
            with self.assertRaises(ValueError): m.prepare(copy.deepcopy(self.config), tag, 1, 1)
        self.config['team_id'] = 'OTHERTEAM'
        with self.assertRaises(ValueError): m.prepare(self.config, 'v1.1.0', 1, 1)
    def test_rejects_short_tag_even_when_marketing_matches(self):
        config = copy.deepcopy(self.config)
        config['marketing_version'] = '1.2'
        with self.assertRaises(ValueError): m.prepare(config, 'v1.2', 1, 1)
    def test_rejects_invalid_run_attempt_bounds(self):
        for run, attempt in [(0, 1), (9900, 1), (10**6, 1), (1, 0), (1, 100), (1, 10**3)]:
            with self.assertRaises(ValueError):
                m.prepare(copy.deepcopy(self.config), 'v1.1.0', run, attempt)
    def test_accepts_run_attempt_at_exact_limits(self):
        lo = m.prepare(copy.deepcopy(self.config), 'v1.1.0', 1, 1)['project_version']
        hi = m.prepare(copy.deepcopy(self.config), 'v1.1.0', 9899, 99)['project_version']
        self.assertEqual((lo, hi), ('101.1', '9999.99'))
    def test_rejects_bad_sparkle_pubkey(self):
        for raw in (bytes(31), bytes(33), bytes(64)):
            bad = copy.deepcopy(self.config)
            bad['macos']['info_plist']['SUPublicEDKey'] = base64.b64encode(raw).decode()
            with self.assertRaises(ValueError): m.prepare(bad, 'v1.1.0', 1, 1)
        bad = copy.deepcopy(self.config)
        bad['macos']['info_plist']['SUPublicEDKey'] = '!!!not-base64!!!'
        with self.assertRaises(ValueError): m.prepare(bad, 'v1.1.0', 1, 1)
    def test_rejects_bundle_id_mismatch(self):
        bad = copy.deepcopy(self.config)
        bad['bundle_id'] = 'works.relux.runnercontrol.evil'
        with self.assertRaises(ValueError): m.prepare(bad, 'v1.1.0', 1, 1)
    def test_rejects_wrong_feed(self):
        self.config['macos']['info_plist']['SUFeedURL'] = 'https://example.org/feed'
        with self.assertRaises(ValueError): m.prepare(self.config, 'v1.1.0', 1, 1)
    def test_appcast_archive_binding(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'
            xml = f'''<rss xmlns:sparkle="{m.NS[1:-1]}"><channel><item>
              <sparkle:version>101.1</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
              <enclosure url="https://github.com/{m.REPO}/releases/download/v1.1.0/RunnerControl.dmg"
              length="7" sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"/>
              </item></channel></rss>'''
            feed.write_text(xml)
            m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
            for bad in [xml.replace('length="7"', 'length="8"'), xml.replace('/v1.1.0/', '/v9.0.0/'),
                        xml.replace('101.1', '100.1'), xml.replace('14.0', '13.0')]:
                feed.write_text(bad)
                with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
    def test_rejects_short_version_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'
            feed.write_text(_appcast(dmg, short='9.9.9'))
            with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
    def test_rejects_wrong_item_count(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'
            feed.write_text(_appcast(dmg, items=0))
            with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
            feed.write_text(_appcast(dmg, items=2))
            with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
    def test_rejects_bad_signature(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'
            for sig in ['', base64.b64encode(bytes(32)).decode(), '!!!not-base64!!!']:
                feed.write_text(_appcast(dmg, sig=sig))
                with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
    def test_rejects_missing_enclosure_and_minimum(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'
            feed.write_text(_appcast(dmg, enclosure=False))
            with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
            feed.write_text(_appcast(dmg, minimum=None))
            with self.assertRaises(ValueError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')
    def test_malformed_appcast_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            dmg = Path(d) / 'RunnerControl.dmg'; dmg.write_bytes(b'archive')
            feed = Path(d) / 'appcast.xml'; feed.write_text('<rss><channel><item>')
            import xml.etree.ElementTree as ET
            with self.assertRaises(ET.ParseError): m.verify_appcast(feed, dmg, 'v1.1.0', '101.1')


def _appcast(dmg, short='1.1.0', build='101.1', sig=None, items=1, enclosure=True, minimum='14.0'):
    sig = base64.b64encode(bytes(64)).decode() if sig is None else sig
    enc = (f'<enclosure url="https://github.com/{m.REPO}/releases/download/v1.1.0/RunnerControl.dmg" '
           f'length="{dmg.stat().st_size}" sparkle:edSignature="{sig}"/>') if enclosure else ''
    mintag = f'<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>' if minimum else ''
    item = (f'<item><sparkle:version>{build}</sparkle:version>'
            f'<sparkle:shortVersionString>{short}</sparkle:shortVersionString>{mintag}{enc}</item>')
    return (f'<rss xmlns:sparkle="{m.NS[1:-1]}"><channel>' + item * items + '</channel></rss>')

TEAM = '262RZ595FP'
EXPECTED_SHA = '267D90FC976A48CF830BE7F41AE612999E025054'
FIND_IDENTITY = (
    '  1) 7FB8D981868F2637B75DFD098A1F87E0CC11158D "Apple Development: Ivan Oparin (45W9YW7M6V)"\n'
    '  2) 08EF92AE3835F98861F51E625FAA9B6900A075C7 "Apple Development: Ivan Oparin (FSPBF3QRXT)"\n'
    f'  3) {EXPECTED_SHA} "Developer ID Application: Relux Works, LLC ({TEAM})"\n'
    '  4) C8448515B5871071F90EB0168A79DCD35E7CA9FE "Developer ID Application: SKL VC DMCC (4Y4UJAT8QR)"\n'
    '     4 valid identities found\n')

class SigningIdentityTests(unittest.TestCase):
    def test_returns_team_identity_ignoring_other_teams(self):
        self.assertEqual(m.resolve_signing_identity(FIND_IDENTITY, TEAM), EXPECTED_SHA)
    def test_rejects_missing_team_identity(self):
        only_other = '\n'.join(l for l in FIND_IDENTITY.splitlines() if TEAM not in l)
        with self.assertRaises(ValueError): m.resolve_signing_identity(only_other, TEAM)
    def test_rejects_apple_development_only(self):
        dev_only = '\n'.join(l for l in FIND_IDENTITY.splitlines() if 'Apple Development' in l)
        with self.assertRaises(ValueError): m.resolve_signing_identity(dev_only, TEAM)
    def test_rejects_same_team_apple_development(self):
        same_team_dev = FIND_IDENTITY.splitlines()[0].replace('(45W9YW7M6V)', f'({TEAM})')
        with self.assertRaises(ValueError): m.resolve_signing_identity(same_team_dev, TEAM)
    def test_rejects_near_match_team(self):
        near = FIND_IDENTITY.replace(f'({TEAM})', '(262RZ595FX)')
        with self.assertRaises(ValueError): m.resolve_signing_identity(near, TEAM)
    def test_rejects_multiple_team_identities(self):
        extra = FIND_IDENTITY.replace('  4) C8448515B5871071F90EB0168A79DCD35E7CA9FE "Developer ID Application: SKL VC DMCC (4Y4UJAT8QR)"',
                                      f'  4) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Relux Works, LLC ({TEAM})"')
        with self.assertRaises(ValueError): m.resolve_signing_identity(extra, TEAM)

class ReleaseWiringTests(unittest.TestCase):
    def test_release_signs_dmg_with_resolved_team_identity(self):
        lines = (Path(__file__).parents[1] / 'release.sh').read_text().splitlines()
        live = [l for l in lines if not l.lstrip().startswith('#')]
        self.assertTrue(any('release_metadata.py signing-identity' in l and '--team 262RZ595FP' in l for l in live),
                        'release.sh must resolve the DMG signing identity through release_metadata.py signing-identity')

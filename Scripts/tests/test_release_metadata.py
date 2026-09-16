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
        for tag in ['v1.0.0', 'main', 'v1.1.0;echo']:
            with self.assertRaises(ValueError): m.prepare(copy.deepcopy(self.config), tag, 1, 1)
        self.config['team_id'] = 'OTHERTEAM'
        with self.assertRaises(ValueError): m.prepare(self.config, 'v1.1.0', 1, 1)
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

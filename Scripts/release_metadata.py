#!/usr/bin/env python3
"""Validate release identity and appcast metadata without handling private keys."""
import argparse
import base64
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

REPO = 'relux-works/runner-control'
FEED = f'https://github.com/{REPO}/releases/latest/download/appcast.xml'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def prepare(config, tag, run, attempt):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Release tag must be vMAJOR.MINOR.PATCH')
    if config['marketing_version'] != tag[1:]:
        raise ValueError('Tag must match marketing_version in ios-app-manager.json')
    if config['bundle_id'] != 'works.relux.runnercontrol' or config['team_id'] != '262RZ595FP':
        raise ValueError('Unexpected bundle ID or signing team')
    if not 1 <= run <= 9899 or not 1 <= attempt <= 99:
        raise ValueError('Invalid release run/attempt number')
    if config['macos']['info_plist']['SUFeedURL'] != FEED:
        raise ValueError('Unexpected public update feed')
    key = base64.b64decode(config['macos']['info_plist']['SUPublicEDKey'], validate=True)
    if len(key) != 32:
        raise ValueError('Invalid Sparkle public key')
    config['project_version'] = f'{100 + run}.{attempt}'
    return config

def verify_appcast(path, dmg, tag, build):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one current release in appcast')
    item = items[0]
    if item.findtext(NS + 'version') != build:
        raise ValueError('Appcast build does not match app build')
    if item.findtext(NS + 'shortVersionString') != tag[1:]:
        raise ValueError('Appcast release version mismatch')
    enclosure = item.find('enclosure')
    if enclosure is None or enclosure.get('url') != f'https://github.com/{REPO}/releases/download/{tag}/RunnerControl.dmg':
        raise ValueError('Unexpected download URL')
    signature = base64.b64decode(enclosure.get(NS + 'edSignature', ''), validate=True)
    if len(signature) != 64 or int(enclosure.get('length', '0')) != dmg.stat().st_size:
        raise ValueError('Missing signature or archive length mismatch')
    minimum = item.findtext(NS + 'minimumSystemVersion')
    if not minimum or int(minimum.split('.')[0]) < 14:
        raise ValueError('Missing minimum macOS requirement')

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--config', type=Path, required=True)
    prep.add_argument('--tag', required=True)
    prep.add_argument('--run', type=int, required=True)
    prep.add_argument('--attempt', type=int, required=True)
    verify = sub.add_parser('verify')
    verify.add_argument('--appcast', type=Path, required=True)
    verify.add_argument('--dmg', type=Path, required=True)
    verify.add_argument('--tag', required=True)
    verify.add_argument('--build', required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        data = prepare(json.loads(args.config.read_text()), args.tag, args.run, args.attempt)
        args.config.write_text(json.dumps(data, indent=2) + '\n')
        print(data['project_version'])
    else:
        verify_appcast(args.appcast, args.dmg, args.tag, args.build)
        print('Appcast identity, signature presence, size and minimum OS verified')

if __name__ == '__main__':
    main()

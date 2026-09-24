#!/usr/bin/env python3
"""Prepare a verified release's signed update feed. Does not publish anything."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import release

ROOT = Path(__file__).resolve().parents[2]
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate_receipt(receipt, archive, info, config):
    channel = receipt.get('channel')
    expected_id = 'com.ethdawg.workbench' + ('.preview' if channel == 'preview' else '')
    expected_feed = config['feed_base'] + '/' + str(channel) + '.xml'
    if channel not in ('production', 'preview'):
        raise RuntimeError('Unknown receipt channel')
    if hashlib.sha256(archive.read_bytes()).hexdigest() != receipt.get('sha256'):
        raise RuntimeError('Archive checksum differs from the release receipt')
    matches = {'CFBundleIdentifier': expected_id, 'WorkbenchBuildKind': 'release',
               'WorkbenchSourceRevision': receipt.get('source'), 'WorkbenchSourceDirty': False,
               'CFBundleVersion': receipt.get('build'), 'CFBundleShortVersionString': receipt.get('version'),
               'SUPublicEDKey': config['public_key'], 'SUFeedURL': expected_feed,
               'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}
    if any(info.get(k) != v for k, v in matches.items()) or not receipt.get('notarization'):
        raise RuntimeError('Package identity, update policy or release provenance differs from receipt')
    if not re.fullmatch(r'[0-9a-f]{40}', str(receipt.get('source'))):
        raise RuntimeError('Release source must be an exact commit')


def validate_feed(path, receipt, url, length):
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    matching = [i for i in items if i.findtext(SPARKLE + 'version') == receipt['build']]
    if len(matching) != 1:
        raise RuntimeError('Feed must identify the exact delivered build once')
    item = matching[0]
    enclosure = item.find('enclosure')
    if enclosure is None or enclosure.get('url') != url or enclosure.get('length') != str(length) or not enclosure.get(SPARKLE + 'edSignature'):
        raise RuntimeError('Feed points to different or unsigned bytes')
    if item.findtext(SPARKLE + 'minimumSystemVersion') != '14.0':
        raise RuntimeError('Feed must retain the supported macOS minimum')


def prepare(directory, tag, notes, output):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-preview\.[0-9]+)?', tag):
        raise RuntimeError('Use a semantic release tag, e.g. v2.0.0-preview.5')
    receipt = json.loads((directory / 'release.json').read_text())
    if (receipt['channel'] == 'preview') != ('-preview.' in tag):
        raise RuntimeError('Tag and package edition differ')
    config = json.loads((ROOT / 'scripts/release/updates.json').read_text())
    name = receipt['archive']
    if Path(name).name != name:
        raise RuntimeError('Archive must be inside the release directory')
    archive = directory / name
    package = release.configuration(ROOT, preview=receipt['channel'] == 'preview')
    release.validate_archive(archive, package)
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='workbench-feed-') as temporary:
        extracted = Path(temporary)
        subprocess.run(['ditto', '-x', '-k', archive, extracted], check=True)
        app = extracted / package['bundle']
        info = release.validate_identity(app, package)
        validate_receipt(receipt, archive, info, config)
        release.check_signature(app, receipt['team'])
        subprocess.run(['xcrun', 'stapler', 'validate', app], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', app], check=True)
    filename = name.replace(' ', '.')
    destination = output / filename
    shutil.copy2(archive, destination)
    shutil.copy2(notes, output / (Path(filename).stem + '.html'))
    base = f'https://github.com/EthDawg/workbench/releases/download/{tag}/'
    tool = ROOT / '.build/artifacts/sparkle/Sparkle/bin/generate_appcast'
    feed = output / (receipt['channel'] + '.xml')
    previous = ROOT / 'site/updates' / feed.name
    if previous.exists():
        old = ET.parse(previous).getroot().findall('.//' + SPARKLE + 'version')
        if any(tuple(map(int, e.text.split('.'))) >= tuple(map(int, receipt['build'].split('.'))) for e in old):
            raise RuntimeError('New release must advance the published build number')
        shutil.copy2(previous, feed)
    subprocess.run([tool, '--account', config['keychain_account'], '--download-url-prefix', base,
                    '--embed-release-notes', '--maximum-deltas', '0', '-o', feed, output], check=True)
    validate_feed(feed, receipt, base + filename, destination.stat().st_size)
    subprocess.run([tool.parent / 'sign_update', '--account', config['keychain_account'], '--verify', feed], check=True)
    receipt.update(archive=filename, tag=tag, download_url=base + filename,
                   feed_url=config['feed_base'] + '/' + feed.name)
    (output / 'release.json').write_text(json.dumps(receipt, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(f"{receipt['sha256']}  {filename}\n")
    print(f'Prepared {output}. Publish and read back the assets before deploying {feed.name}.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--notes', type=Path, required=True, help='HTML fragment; embedded in signed feed')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.release, args.tag, args.notes, args.output)

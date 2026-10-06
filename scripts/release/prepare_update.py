#!/usr/bin/env python3
"""Prepare a verified release's signed update feed. Does not publish anything."""
import argparse
from datetime import datetime, timezone
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


def validate_tag(receipt, tag):
    match = re.fullmatch(r'v([0-9]+\.[0-9]+\.[0-9]+)(?:-preview\.([0-9]+)|\+([0-9]+(?:\.[0-9]+)*))?', tag)
    if not match or match[1] != receipt['version']:
        raise RuntimeError('Release tag must match the packaged version')
    if (receipt['channel'] == 'preview') != bool(match[2]):
        raise RuntimeError('Tag and package edition differ')
    if match[3] is not None and match[3] != receipt.get('build'):
        raise RuntimeError('Release tag build must match the packaged build')


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
    if item.findtext(SPARKLE + 'shortVersionString') != receipt['version']:
        raise RuntimeError('Feed display version differs from the package')
    return enclosure.get(SPARKLE + 'edSignature')


def verify_package(receipt, archive, config):
    """Recheck the actual signed app at both preparation and publication."""
    package = release.configuration(ROOT, preview=receipt['channel'] == 'preview')
    release.validate_archive(archive, package)
    with tempfile.TemporaryDirectory(prefix='workbench-feed-') as temporary:
        extracted = Path(temporary)
        subprocess.run(['ditto', '-x', '-k', archive, extracted], check=True)
        app = extracted / package['bundle']
        info = release.validate_identity(app, package, incoming=True)
        validate_receipt(receipt, archive, info, config)
        release.check_signature(app, receipt['team'])
        subprocess.run(['xcrun', 'stapler', 'validate', app], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', app], check=True)
        return info


# This is a small artifact gate, not proof that an observer's attestation is true.
JOURNEY_IDS = set('D1 M1 M2 H1 H2 S1 ST1 P1 P2 R1 U1 U2 I1 I2 Q1 Q2 Q3 L1 L2 L3 L4 X1 X2 X3'.split())
ACCEPTANCE_NAME = 'journey-acceptance.json'


def read_json_bytes(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('Invalid JSON constant: ' + value)
    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=invalid)
    except (ValueError, UnicodeError) as error:
        raise RuntimeError('Invalid acceptance JSON') from error


def policy_digest(policy):
    return hashlib.sha256(json.dumps(policy, sort_keys=True, separators=(',', ':'),
                                     allow_nan=False).encode()).hexdigest()


def validate_acceptance(directory, receipt, info, root):
    """Return only the validated public bytes, before preparation or publication writes."""
    def require(condition, message):
        if not condition:
            raise RuntimeError('Release acceptance: ' + message)
    def text(value):
        return isinstance(value, str) and bool(value.strip())
    def digest(value):
        return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None
    def regular_bytes(path):
        require(not path.is_symlink() and path.is_file(), 'missing or symlink evidence')
        require(path.stat().st_size <= 8 * 1024 * 1024, 'evidence exceeds 8 MiB')
        return path.read_bytes()
    try:
        policy = read_json_bytes((root / 'scripts/release/config.json').read_bytes())['acceptance']
        require(policy['schemaVersion'] == 1 and policy['claim'] in ('bounded-slice', 'foundation-candidate'), 'unknown policy')
        require(text(policy['impact']['reason']) and policy['impact']['packages']
                and set(policy['impact']['packages']) <= set('ABCDEFGHIJ'), 'missing reviewed slice impact')
        rows = policy['journeys']
        require(isinstance(rows, list) and rows, 'empty journey policy')
        expected = {}
        for row in rows:
            key = (row['id'], row['variant'])
            require(row['id'] in JOURNEY_IDS and text(row['variant']) and key not in expected, 'unknown or duplicate policy journey')
            require(row['phase'] in ('candidate', 'delivery'), 'unknown journey phase')
            require(row['phase'] != 'delivery' or row['id'] in ('I1', 'U2'), 'invalid delivery-only journey')
            expected[key] = row['phase']
        if policy['claim'] == 'foundation-candidate':
            require({key[0] for key in expected} == JOURNEY_IDS, 'incomplete foundation policy')
        sidecar = regular_bytes(directory / ACCEPTANCE_NAME)
        acceptance = read_json_bytes(sidecar)
        require(acceptance['schemaVersion'] == 1 and acceptance['stage'] == 'candidate', 'unknown schema or stage')
        require(acceptance['publicationReady'] is True and acceptance['resetComplete'] is False, 'partial or premature completion claim')
        require(acceptance['policySHA256'] == policy_digest(policy), 'different reviewed policy')
        artifact = {key: receipt[key] for key in ('source', 'channel', 'version', 'build', 'sha256')}
        artifact['bundle'] = info['CFBundleIdentifier']
        require(acceptance['artifact'] == artifact, 'different package identity')
        require(info['WorkbenchBuildKind'] == 'release' and info['WorkbenchSourceDirty'] is False, 'local or dirty package')
        for key, field in [('source', 'WorkbenchSourceRevision'), ('version', 'CFBundleShortVersionString'), ('build', 'CFBundleVersion')]:
            require(artifact[key] == info[field], 'different verified bundle')
        require(all(text(acceptance[key]) for key in ('observer', 'reviewer', 'observedAt')), 'missing observation/review')
        observed = datetime.fromisoformat(acceptance['observedAt'].replace('Z', '+00:00'))
        require(observed.utcoffset() is not None, 'observation time needs an explicit offset')
        require(observed <= datetime.now(timezone.utc), 'observation is in the future')
        require(acceptance['reviewer'] != acceptance['observer'], 'independent review required')
        require(all(text(acceptance['environment'][key]) for key in ('macOS', 'hardware')), 'missing native environment')
        require(acceptance['candidateSmoke']['method'] == 'native' and acceptance['candidateSmoke']['status'] == 'pass', 'fresh native candidate smoke required')
        require(all(acceptance['candidateSmoke'][key] == 'pass' for key in ('opening', 'permissions', 'savedWork')), 'exact-edition opening, permissions and saved-work smoke required')
        files = {ACCEPTANCE_NAME: sidecar}
        evidence = {}
        require(isinstance(acceptance['evidence'], list) and 0 < len(acceptance['evidence']) <= 64, 'missing or excessive evidence')
        for item in acceptance['evidence']:
            name = item['path']
            path = Path(name)
            require(isinstance(name, str) and len(path.parts) == 2 and path.parts[0] == 'acceptance-evidence'
                    and name == 'acceptance-evidence/' + path.name
                    and path.name not in (ACCEPTANCE_NAME, 'release.json', 'SHA256SUMS.txt', receipt['archive'], receipt['archive'].replace(' ', '.'))
                    and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', path.name), 'unsafe evidence path')
            require(name not in evidence and item['sanitized'] is True and digest(item['sha256']), 'duplicate or unsanitized evidence')
            require(not (directory / 'acceptance-evidence').is_symlink(), 'symlink evidence directory')
            data = regular_bytes(directory / path)
            require(hashlib.sha256(data).hexdigest() == item['sha256'], 'changed evidence bytes')
            evidence[name] = data
            files[name] = data
        def references(names):
            require(isinstance(names, list) and names and len(names) == len(set(names))
                    and all(name in evidence for name in names), 'missing evidence reference')
        references(acceptance['candidateSmoke']['evidence'])
        seen = set()
        for observation in acceptance['journeys']:
            key = (observation['id'], observation['variant'])
            require(key in expected and key not in seen, 'unknown or duplicate journey/variant')
            seen.add(key)
            if expected[key] == 'delivery':
                require(observation['status'] == 'not-tested', 'public delivery cannot be pre-attested')
                continue
            require(observation['status'] == 'pass' and observation['method'] == 'native', 'required native journey has not passed')
            references(observation['evidence'])
            reuse = observation.get('reuse')
            if reuse is not None:
                original = reuse['artifact']
                require(all(text(original[k]) for k in ('source', 'channel', 'version', 'build', 'bundle'))
                        and digest(original['sha256']), 'missing original artifact')
                require(re.fullmatch(r'[0-9a-f]{40}', original['source']) is not None, 'invalid original source')
                require(all(text(reuse['environment'][k]) for k in ('macOS', 'hardware')), 'missing original environment')
                require(all(text(reuse[k]) for k in ('sourceImpact', 'configurationImpact', 'environmentImpact', 'reviewer')), 'unreviewed historical reuse')
                references(reuse['evidence'])
        require(seen == set(expected), 'missing required journey/variant')
        compatibility = acceptance['compatibility']
        baseline = read_json_bytes((root / 'site/updates' / (receipt['channel'] + '.json')).read_bytes())
        require(compatibility['previousRelease'] == {k: baseline[k] for k in ('source', 'version', 'build', 'sha256')}, 'wrong storage baseline')
        require(text(compatibility['reviewer']) and text(compatibility['assessment']), 'unassessed storage compatibility')
        references(compatibility['upgradeEvidence'])
        require(isinstance(compatibility['formats'], list) and compatibility['formats'], 'missing persisted-format assessment')
        formats = set()
        for item in compatibility['formats']:
            require(text(item['name']) and item['name'] not in formats and text(item['upgrade'])
                    and item['downgrade'] in ('supported', 'unsupported') and text(item['recovery']), 'incomplete format compatibility')
            formats.add(item['name'])
        require(formats == set(policy['storageFormats']) and len(formats) == len(policy['storageFormats']), 'missing required format assessment')
        return files
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise RuntimeError('Release acceptance: missing or malformed receipt, policy or evidence') from error


def prepare(directory, tag, notes, output):
    receipt = json.loads((directory / 'release.json').read_text())
    validate_tag(receipt, tag)
    config = json.loads((ROOT / 'scripts/release/updates.json').read_text())
    name = receipt['archive']
    if Path(name).name != name:
        raise RuntimeError('Archive must be inside the release directory')
    archive = directory / name
    info = verify_package(receipt, archive, config)
    evidence = validate_acceptance(directory, receipt, info, ROOT)
    output.mkdir(parents=True, exist_ok=False)
    for name, data in evidence.items():
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    filename = receipt['archive'].replace(' ', '.')
    destination = output / filename
    shutil.copy2(archive, destination)
    shutil.copy2(notes, output / (Path(filename).stem + '.html'))
    base = f'https://github.com/Ship-Work/workbench/releases/download/{tag}/'
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

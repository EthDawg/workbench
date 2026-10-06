#!/usr/bin/env python3
"""Stamp the actual package, never a mutable tracked Info.plist."""
import json
import os
import re
from pathlib import Path
import plistlib
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
REPORTING_KEYS = ('WorkbenchReportDSN', 'WorkbenchReportVerifierURL')


def reporting(config):
    """Report a problem (#296): the Stable release's Sentry DSN (a public client key) and optional
    delivery verifier. Preview and local builds carry neither; a developer override sends from them
    under the preview environment instead (docs/bug-reporting.md)."""
    dsn = config.get('dsn', '')
    if not re.fullmatch(r'https://[A-Za-z0-9]+@[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*/[0-9]+', dsn):
        raise RuntimeError('scripts/release/reporting.json needs the Stable edition\'s https Sentry DSN')
    verifier = config.get('verifier', '')
    if verifier and not re.fullmatch(r'https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/?', verifier):
        raise RuntimeError('The report verifier must be an https URL without credentials, query or fragment')
    return dsn, verifier

def stamp(info, channel, *, released=False, source=None, dirty=None, build=None):
    config = json.loads((ROOT / 'scripts/release/updates.json').read_text())
    if channel not in ('production', 'preview'):
        raise RuntimeError('Unknown update channel')
    if source is None:
        source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if dirty is None:
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    scheme = 'workbench-preview' if channel == 'preview' else 'workbench'
    info['CFBundleURLTypes'] = [{'CFBundleURLName': 'Workbench pack links', 'CFBundleURLSchemes': [scheme], 'CFBundleTypeRole': 'Viewer'}]
    if released and dirty:
        raise RuntimeError('A release must come from committed source')
    if released and tuple(int(part) for part in info.get('CFBundleShortVersionString', '0.0.0').split('.')) >= (2, 2, 0):
        client = info.get('WorkbenchGitHubClientID', '')
        if not isinstance(client, str) or len(client) < 8 or not all(c.isascii() and (c.isalnum() or c in '._') for c in client):
            raise RuntimeError('Register the GitHub App device flow and set its public WorkbenchGitHubClientID before publishing Workbench 2.2')
    info.update(WorkbenchSourceRevision=source, WorkbenchSourceDirty=dirty,
                WorkbenchBuildKind='release' if released else 'local',
                CFBundleVersion=build or datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'))
    for key in ['SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate',
                'SUEnableSystemProfiling', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction', *REPORTING_KEYS]:
        info.pop(key, None)
    if released and channel == 'production':
        dsn, verifier = reporting(json.loads((ROOT / 'scripts/release/reporting.json').read_text())['production'])
        info['WorkbenchReportDSN'] = dsn
        if verifier:
            info['WorkbenchReportVerifierURL'] = verifier
    if released:
        info.update(SUFeedURL=f"{config['feed_base']}/{channel}.xml", SUPublicEDKey=config['public_key'],
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUEnableSystemProfiling=False,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    return info

if __name__ == '__main__':
    path = Path(sys.argv[1])
    info = stamp(plistlib.loads(path.read_bytes()), sys.argv[2], released=os.environ.get('WORKBENCH_RELEASE') == '1')
    path.write_bytes(plistlib.dumps(info))

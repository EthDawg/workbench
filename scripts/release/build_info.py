#!/usr/bin/env python3
"""Stamp the actual package, never a mutable tracked Info.plist."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]

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
                'SUEnableSystemProfiling', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
        info.pop(key, None)
    if released:
        info.update(SUFeedURL=f"{config['feed_base']}/{channel}.xml", SUPublicEDKey=config['public_key'],
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUEnableSystemProfiling=False,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    return info

if __name__ == '__main__':
    path = Path(sys.argv[1])
    info = stamp(plistlib.loads(path.read_bytes()), sys.argv[2], released=os.environ.get('WORKBENCH_RELEASE') == '1')
    path.write_bytes(plistlib.dumps(info))

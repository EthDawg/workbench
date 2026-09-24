#!/usr/bin/env python3
"""Read installed and downloaded Workbench copies without changing any files."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import subprocess

IDENTITIES = {'com.ethdawg.workbench','com.ethdawg.workbench.preview','com.ethdawg.localvoice','com.ethdawg.localvoice.preview','local.ethan.StageMark','local.ethan.StageMark.preview'}

def inventory(roots=None):
    rows=[]
    installed_roots=[Path('/Applications'),Path.home()/'Applications']
    downloads=Path.home()/'Downloads'
    for root in roots or [*installed_roots,downloads]:
        root=Path(root)
        location='installed' if root in installed_roots else 'downloaded' if root == downloads else 'other'
        for app in root.glob('*.app'):
            path=app/'Contents/Info.plist'
            try: info=plistlib.loads(path.read_bytes())
            except (OSError,ValueError): continue
            identity=info.get('CFBundleIdentifier')
            if identity not in IDENTITIES: continue
            signature=subprocess.run(['codesign','-dv','--verbose=2',str(app)],capture_output=True,text=True).stderr
            team=next((line.split('=',1)[1] for line in signature.splitlines() if line.startswith('TeamIdentifier=')),None)
            rows.append(dict(path=str(app),identity=identity,version=info.get('CFBundleShortVersionString'),build=info.get('CFBundleVersion'),
                source=info.get('WorkbenchSourceRevision','not recorded'),kind=info.get('WorkbenchBuildKind','legacy/unrecorded'),
                edition='Preview' if identity.endswith('.preview') else 'Stable',legacy=identity not in {'com.ethdawg.workbench','com.ethdawg.workbench.preview'},
                team=team,feed=info.get('SUFeedURL'),location=location))
    counts=Counter(row['identity'] for row in rows)
    for row in rows: row['duplicate_identity']=counts[row['identity']] > 1
    return rows


def print_inventory(rows):
    locations={'installed':'Installed', 'downloaded':'Downloaded (not installed)', 'other':'Other location (not an Applications install)'}
    for row in rows:
        print(f"{row['path']}\n  {locations[row['location']]} · {row['edition']} {row['version']} ({row['build']}) · {row['kind']} · source {row['source']}")
    if any(r['legacy'] for r in rows): print('Legacy app copies remain. Preserve their data and verify migration before retiring their binaries.')
    for identity,count in Counter(row['identity'] for row in rows).items():
        if count > 1:
            print(f'Warning: {count} copies share identity {identity}. Keep one installed copy in Applications. Verify its build and preserve a recovery archive before retiring leftover extracted copies; saved-data folders stay in place.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--json',action='store_true');args=parser.parse_args()
    rows=inventory()
    if args.json: print(json.dumps(rows,indent=2))
    else: print_inventory(rows)

#!/usr/bin/env python3
"""Read actual installed Workbench identities; never infer installation from Git."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

IDENTITIES = {'com.ethdawg.workbench','com.ethdawg.workbench.preview','com.ethdawg.localvoice','com.ethdawg.localvoice.preview','local.ethan.StageMark','local.ethan.StageMark.preview'}

def inventory(roots=None):
    rows=[]
    for root in roots or [Path('/Applications'),Path.home()/'Applications']:
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
                team=team,feed=info.get('SUFeedURL')))
    return rows

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--json',action='store_true');args=parser.parse_args()
    rows=inventory()
    if args.json: print(json.dumps(rows,indent=2))
    else:
        for row in rows:
            print(f"{row['path']}\n  {row['edition']} {row['version']} ({row['build']}) · {row['kind']} · source {row['source']}")
        if any(r['legacy'] for r in rows): print('Legacy app copies remain. Preserve their data and verify migration before retiring their binaries.')
        if len({r['identity'] for r in rows}) != len(rows): print('Duplicate copies share an identity. Resolve the installed path before replacing either copy.')

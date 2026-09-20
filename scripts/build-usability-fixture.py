#!/usr/bin/env python3
"""Package the real debug app with disposable storage; never launch or install it.

Run swift build --disable-sandbox first. Pass a new temporary root, for example
/private/tmp/workbench-usability-20260920. Release builds ignore this fixture.
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

project = Path(__file__).resolve().parents[1]
root = Path(sys.argv[1]).resolve()
if root.parent != Path('/private/tmp') or not root.name.startswith('workbench-usability-'):
    raise SystemExit('Choose a new /private/tmp/workbench-usability-* directory.')
binary = project / '.build/debug/LocalVoice'
if not binary.is_file():
    raise SystemExit('Run swift build --disable-sandbox first.')
root.mkdir(mode=0o700, exist_ok=False)
app = root / 'Workbench Usability QA.app'
macos = app / 'Contents/MacOS'
resources = app / 'Contents/Resources'
macos.mkdir(parents=True)
resources.mkdir()
shutil.copy2(binary, macos / 'WorkbenchUsabilityQA')
for bundle in (project / '.build/debug').glob('*.bundle'):
    shutil.copytree(bundle, resources / bundle.name)
for name in ['SceneBackdrops', 'AmbientScenes', 'PersonaPortraits']:
    shutil.copytree(project / 'Resources' / name, resources / name)
shutil.copy2(project / 'scripts/AppIcon.icns', resources / 'AppIcon.icns')
with (project / 'scripts/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
info.update(CFBundleExecutable='WorkbenchUsabilityQA', CFBundleName='Workbench Usability QA',
            CFBundleDisplayName='Workbench Usability QA',
            CFBundleIdentifier='local.workbench.usability-' + uuid.uuid4().hex,
            WorkbenchFixtureRoot=str(root / 'data'), WorkbenchChannel='preview')
info.pop('NSServices', None)
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
print(app)

#!/usr/bin/env python3
"""Open the installed Preview's real History views with disposable gallery data.

Quit both Workbench editions first. The output must be a new directory; it holds
synthetic stores, preferences and history-acceptance.json for external-edit tests.
No app is installed, identity changed, live store replaced or provider launched.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--updates', action='store_true', help='Use the isolated sidebar updater fixture instead of History; no app is replaced')
    parser.add_argument('--theme', choices=('light', 'dark'), default='light')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'com.ethdawg.workbench.preview':
        parser.error('Use the existing Workbench Preview identity.')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Match SurfaceGallery's path spelling: no /tmp or /var symlink in stores.
    if str(output).startswith('/private/'):
        output = Path('/System/Volumes/Data' + str(output))
    root = Path(tempfile.mkdtemp(prefix='.surface-pass-', dir=output))
    fixture_home, temporary, preferences = root / 'home', root / 'tmp', root / 'preferences'
    for folder in (fixture_home, temporary, preferences):
        folder.mkdir(mode=0o700)
    environment = dict(os.environ, CFFIXED_USER_HOME=str(fixture_home), HOME=str(fixture_home),
                       TMPDIR=str(temporary) + '/', TZ='UTC')
    command = [str(executable), '--render-surfaces-pass', str(output), args.theme,
               '--interactive-updates' if args.updates else '--interactive-history',
               '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
    print(f'Synthetic native acceptance: {output}', flush=True)
    print('Close with the acceptance menu’s Quit command. Fixture data is retained.', flush=True)
    return subprocess.call(command, env=environment)


if __name__ == '__main__':
    raise SystemExit(main())

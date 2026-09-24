#!/usr/bin/env python3
"""Publish prepared bytes, verify the public download, then stage their signed feed.

Uses the maintainer's existing gh authentication. Does not merge or deploy a site.
A failed run must be reconciled against the existing release before retrying.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import prepare_update

ROOT = Path(__file__).resolve().parents[2]
REPO = 'EthDawg/workbench'


def gh(*args):
    return subprocess.check_output(['gh', *map(str,args)], text=True)


def verify_tag_target(tag, source):
    refs = json.loads(gh('api', f'repos/{REPO}/git/matching-refs/tags/{tag}'))
    ref = next((r for r in refs if r['ref'] == f'refs/tags/{tag}'), None)
    if ref is None:
        return  # release create will create it at the supplied source
    target = ref['object']
    for _ in range(8):
        if target['type'] != 'tag':
            break
        target = json.loads(gh('api', f"repos/{REPO}/git/tags/{target['sha']}"))['object']
    if target['type'] != 'commit' or target['sha'] != source:
        raise RuntimeError('Existing release tag points to different source; no write performed')


def website_record(receipt, feed):
    """Bind the website selection to the exact feed verified for publication."""
    record = {key: receipt[key] for key in
              ['channel', 'version', 'build', 'tag', 'source', 'download_url', 'sha256', 'feed_url']}
    record['feed_sha256'] = hashlib.sha256(feed.read_bytes()).hexdigest()
    return record


def require_newer_build(previous, build):
    if previous.exists():
        versions = ET.parse(previous).getroot().findall('.//' + prepare_update.SPARKLE + 'version')
        if any(tuple(map(int, version.text.split('.'))) >= tuple(map(int, build.split('.')))
               for version in versions):
            raise RuntimeError('A same or newer feed is already staged. No feed replaced.')


def publish(directory, notes):
    receipt = json.loads((directory/'release.json').read_text())
    tag, filename = receipt['tag'], receipt['archive']
    if Path(filename).name != filename:
        raise RuntimeError('Unexpected asset filename')
    prepare_update.validate_tag(receipt, tag)
    archive = directory/filename
    if hashlib.sha256(archive.read_bytes()).hexdigest() != receipt['sha256']:
        raise RuntimeError('Prepared archive changed')
    feed = directory/(receipt['channel']+'.xml')
    config=json.loads((ROOT/'scripts/release/updates.json').read_text())
    expected_url = f'https://github.com/{REPO}/releases/download/{tag}/{filename}'
    if receipt['download_url'] != expected_url or receipt['feed_url'] != config['feed_base'] + '/' + feed.name:
        raise RuntimeError('Prepared download or feed URL differs from the release identity')
    if (directory/'SHA256SUMS.txt').read_text() != f"{receipt['sha256']}  {filename}\n":
        raise RuntimeError('Prepared checksum record differs from the archive')
    prepare_update.verify_package(receipt, archive, config)
    signature=prepare_update.validate_feed(feed, receipt, expected_url, archive.stat().st_size)
    signer=ROOT/'.build/artifacts/sparkle/Sparkle/bin/sign_update'
    subprocess.run([signer,'--account',config['keychain_account'],'--verify',feed],check=True)
    subprocess.run([signer,'--account',config['keychain_account'],'--verify',archive,signature],check=True)
    destination = ROOT / 'site/updates'
    previous = destination / feed.name
    # Reject stale prepared artifacts before creating or exposing a release.
    require_newer_build(previous, receipt['build'])
    # Never create duplicate releases or overwrite already published assets.
    listing=[r for page in json.loads(gh('api',f'repos/{REPO}/releases','--paginate','--slurp')) for r in page]
    existing=next((r for r in listing if r['tag_name']==tag),None)
    if existing is not None:
        raise RuntimeError(f'Release {tag} already exists. Reconcile its exact assets before resuming; no write performed.')
    current=json.loads(gh('api',f'repos/{REPO}/branches/main'))['commit']['sha']
    if current != receipt['source']:
        raise RuntimeError('Release source must be current integrated main before publication')
    verify_tag_target(tag, receipt['source'])
    command=['release','create',tag,'--repo',REPO,'--target',receipt['source'],
             '--title',f"Workbench {receipt['version']}" + (' Preview' if receipt['channel']=='preview' else ''),
             '--notes-file',str(notes),'--draft']
    if receipt['channel']=='preview': command.append('--prerelease')
    gh(*command)
    gh('release','upload',tag,archive,directory/'SHA256SUMS.txt',directory/'release.json','--repo',REPO)
    # Verify authenticated draft downloads before exposing the release.
    with tempfile.TemporaryDirectory(prefix='workbench-publish-') as temporary:
        gh('release','download',tag,'--repo',REPO,'--pattern',filename,'--dir',temporary)
        if hashlib.sha256((Path(temporary)/filename).read_bytes()).hexdigest()!=receipt['sha256']:
            raise RuntimeError('Uploaded asset differs; release remains a draft')
    gh('release','edit',tag,'--repo',REPO,'--draft=false')
    with urllib.request.urlopen(receipt['download_url'],timeout=120) as response:
        digest=hashlib.sha256()
        while block:=response.read(1024*1024): digest.update(block)
    if digest.hexdigest()!=receipt['sha256']:
        raise RuntimeError('Public download mismatch; feed has not been promoted')
    # These are the only website files staged by this command. The site selects
    # production.json for the public download and preserves the Preview channel.
    destination.mkdir(parents=True,exist_ok=True)
    # Recheck after network operations in case another publication advanced it.
    require_newer_build(previous, receipt['build'])
    shutil.copy2(feed,previous)
    (destination/(receipt['channel']+'.json')).write_text(json.dumps(website_record(receipt, feed),indent=2)+'\n')
    print(f'Published and verified https://github.com/{REPO}/releases/tag/{tag}')
    print('Signed feed and download record staged in site/updates. Commit, build, deploy and verify them together.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared',type=Path,required=True)
    parser.add_argument('--notes',type=Path,required=True,help='Public Markdown release notes')
    args=parser.parse_args()
    publish(args.prepared,args.notes)

#!/usr/bin/env python3
"""Count how many Macs each Workbench release reached, from GitHub's public download counts.

Workbench sends nothing home. The only adoption evidence that exists is public and
needs no account: every install and every automatic update downloads one release ZIP
from GitHub Releases, and GitHub counts those downloads per asset. So the downloads of
the newest production ZIP are the best available proxy for Macs currently running
Workbench, because every installed copy checks the update feed about once a day and
fetches the new ZIP once. Nothing distinguishes a new person from an updating one.

The counts include the maintainers' own installs, the shared Preview installs and the
link checks that agents run after each publication, so small numbers are mostly us.
Watch the trend, not the digits. Run with --snapshot to keep a dated CSV for trends.
"""
import argparse
import csv
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPOSITORY = 'EthDawg/workbench'
TAG = re.compile(r'^v([0-9]+\.[0-9]+\.[0-9]+)(?:-preview\.([0-9]+)|\+([0-9]+(?:\.[0-9]+)*))?$')
ARCHIVES = {'Workbench.zip': 'production', 'Workbench.Preview.zip': 'preview',
            'Workbench.Voice.zip': 'legacy'}


def fetch_releases(repository=REPOSITORY, opener=urllib.request.urlopen):
    """Read every release page from the public GitHub API, without a token."""
    releases, page = [], 1
    while True:
        request = urllib.request.Request(
            f'https://api.github.com/repos/{repository}/releases?per_page=100&page={page}',
            headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'workbench-adoption'})
        with opener(request) as response:
            batch = json.load(response)
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def parse_time(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def summarise(releases, now):
    """One row per release that shipped an app archive, newest first."""
    rows = []
    for release in releases:
        tag = release.get('tag_name', '')
        match = TAG.match(tag)
        if not match or not release.get('published_at'):
            continue
        archive = next((asset for asset in release.get('assets', []) if asset.get('name') in ARCHIVES), None)
        if archive is None:
            continue
        published = parse_time(release['published_at'])
        days = max((now - published).total_seconds() / 86400, 1 / 24)
        downloads = int(archive.get('download_count', 0))
        rows.append(dict(tag=tag, version=match.group(1), channel=ARCHIVES[archive['name']],
                         published=published.date().isoformat(), days=round(days, 1),
                         downloads=downloads, per_day=round(downloads / days, 2)))
    rows.sort(key=lambda row: row['published'], reverse=True)
    return rows


def headline(rows):
    """The sentence worth reading: what the newest production release reached."""
    current = next((row for row in rows if row['channel'] == 'production'), None)
    if current is None:
        return 'No production release has shipped yet.'
    macs = 'Mac' if current['downloads'] == 1 else 'Macs'
    return (f"Workbench {current['version']} has reached {current['downloads']} {macs} "
            f"in {current['days']:g} days ({current['per_day']:g} a day). "
            'That includes our own installs and link checks.')


def render(rows):
    lines = [headline(rows), '']
    lines.append(f"{'release':<28}{'channel':<12}{'published':<12}{'days':>6}{'downloads':>11}{'per day':>9}")
    for row in rows:
        lines.append(f"{row['tag']:<28}{row['channel']:<12}{row['published']:<12}{row['days']:>6g}"
                     f"{row['downloads']:>11}{row['per_day']:>9g}")
    return '\n'.join(lines)


def snapshot(rows, path, today):
    """Append today's counts once; rerunning on the same day changes nothing."""
    path = Path(path)
    existing = set()
    if path.exists():
        with path.open(newline='') as handle:
            existing = {(row['date'], row['tag']) for row in csv.DictReader(handle)}
    added = [row for row in rows if (today, row['tag']) not in existing]
    if not added:
        return 0
    new_file = not path.exists()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a', newline='') as handle:
        writer = csv.writer(handle)
        if new_file:
            writer.writerow(['date', 'tag', 'channel', 'published', 'downloads'])
        for row in added:
            writer.writerow([today, row['tag'], row['channel'], row['published'], row['downloads']])
    return len(added)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repository', default=REPOSITORY)
    parser.add_argument('--input', type=Path, help='read a saved releases JSON instead of the GitHub API')
    parser.add_argument('--json', action='store_true', help='print the rows as JSON')
    parser.add_argument('--snapshot', type=Path, metavar='CSV', help='append today\'s counts to this CSV')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    releases = json.loads(args.input.read_text()) if args.input else fetch_releases(args.repository)
    rows = summarise(releases, now)
    if args.json:
        print(json.dumps(dict(headline=headline(rows), releases=rows), indent=2))
    else:
        print(render(rows))
    if args.snapshot:
        added = snapshot(rows, args.snapshot, now.date().isoformat())
        print(f'\nSnapshot: {added} row(s) added to {args.snapshot}' if added else f'\nSnapshot: {args.snapshot} already has today')
    return 0


if __name__ == '__main__':
    sys.exit(main())

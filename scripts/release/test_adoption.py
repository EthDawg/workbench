"""Adoption counts from synthetic GitHub release records; no network, no files outside a temp dir."""
from contextlib import redirect_stdout
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import adoption

NOW = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)


def release(tag, published, name='Workbench.zip', downloads=0):
    return dict(tag_name=tag, published_at=published, assets=[
        dict(name='SHA256SUMS.txt', download_count=99), dict(name=name, download_count=downloads)])


RELEASES = [
    release('v2.3.0', '2026-09-28T03:55:00Z', downloads=4),
    release('v2.4.0', '2026-10-01T03:45:40Z', downloads=8),
    release('v2.0.0-preview.4', '2026-09-20T07:14:45Z', name='Workbench.Preview.zip', downloads=5),
    release('v1.2.2', '2026-09-08T13:08:22Z', name='Workbench.Voice.zip', downloads=2),
    dict(tag_name='v9.9.9', published_at='2026-10-02T00:00:00Z', assets=[dict(name='release.json', download_count=7)]),
    dict(tag_name='not-a-release', published_at='2026-10-02T00:00:00Z', assets=[dict(name='Workbench.zip', download_count=7)]),
    dict(tag_name='v2.5.0', published_at=None, assets=[dict(name='Workbench.zip', download_count=0)]),
]


class AdoptionTests(unittest.TestCase):
    def test_rows_keep_only_shipped_archives_newest_first_with_their_channel(self):
        rows = adoption.summarise(RELEASES, NOW)
        self.assertEqual([row['tag'] for row in rows], ['v2.4.0', 'v2.3.0', 'v2.0.0-preview.4', 'v1.2.2'])
        self.assertEqual([row['channel'] for row in rows], ['production', 'production', 'preview', 'legacy'])
        current = rows[0]
        self.assertEqual((current['version'], current['downloads'], current['published']), ('2.4.0', 8, '2026-10-01'))
        self.assertEqual(current['days'], 4.3)
        self.assertEqual(current['per_day'], round(8 / ((NOW - adoption.parse_time('2026-10-01T03:45:40Z')).total_seconds() / 86400), 2))

    def test_a_release_published_minutes_ago_never_divides_by_zero(self):
        rows = adoption.summarise([release('v3.0.0', NOW.isoformat().replace('+00:00', 'Z'), downloads=1)], NOW)
        self.assertEqual(rows[0]['days'], 0)
        self.assertEqual(rows[0]['per_day'], 24.0)

    def test_headline_reads_the_newest_production_release_and_says_who_is_counted(self):
        rows = adoption.summarise(RELEASES, NOW)
        self.assertEqual(adoption.headline(rows),
                         'Workbench 2.4.0 has 8 archive downloads in 4.3 days (1.84 a day). These include repeat downloads and link checks; they do not count unique Macs.')
        one = adoption.summarise([release('v2.4.0', '2026-10-04T12:00:00Z', downloads=1)], NOW)
        self.assertIn('has 1 archive download in 1 day', adoption.headline(one))
        previews = adoption.summarise([release('v2.0.0-preview.4', '2026-09-20T07:14:45Z', name='Workbench.Preview.zip', downloads=5)], NOW)
        self.assertEqual(adoption.headline(previews), 'No production release has shipped yet.')

    def test_same_day_releases_use_full_publication_time(self):
        rows = adoption.summarise([
            release('v2.4.0', '2026-10-01T01:00:00Z', downloads=8),
            release('v2.4.1', '2026-10-01T20:00:00Z', downloads=2),
        ], NOW)
        self.assertEqual([row['tag'] for row in rows], ['v2.4.1', 'v2.4.0'])
        self.assertTrue(adoption.headline(rows).startswith('Workbench 2.4.1 has 2 archive downloads'))

    def test_render_lists_every_row_under_the_headline(self):
        text = adoption.render(adoption.summarise(RELEASES, NOW))
        lines = text.splitlines()
        self.assertTrue(lines[0].startswith('Workbench 2.4.0 has 8 archive downloads'))
        self.assertIn('downloads', lines[2])
        self.assertEqual(len(lines), 3 + 4)
        self.assertRegex(lines[3], r'^v2\.4\.0\s+production\s+2026-10-01\s+4\.3\s+8\s+1\.84$')

    def test_snapshot_appends_once_per_day_and_keeps_earlier_days(self):
        rows = adoption.summarise(RELEASES, NOW)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trend' / 'downloads.csv'
            self.assertEqual(adoption.snapshot(rows, path, '2026-10-05'), 4)
            self.assertEqual(adoption.snapshot(rows, path, '2026-10-05'), 0)
            self.assertEqual(adoption.snapshot(rows, path, '2026-10-06'), 4)
            lines = path.read_text().splitlines()
            self.assertEqual(lines[0], 'date,tag,channel,published,downloads')
            self.assertEqual(len(lines), 1 + 8)
            self.assertIn('2026-10-05,v2.4.0,production,2026-10-01,8', lines)

    def test_fetch_follows_pages_until_a_short_page(self):
        pages = [[release(f'v1.0.{index}', '2026-09-01T00:00:00Z') for index in range(100)], [release('v2.0.0', '2026-09-02T00:00:00Z')]]
        seen = []

        class Response(io.StringIO):
            def __enter__(self): return self
            def __exit__(self, *_): return False

        def opener(request):
            seen.append(request.full_url)
            return Response(json.dumps(pages[len(seen) - 1]))
        releases = adoption.fetch_releases('EthDawg/workbench', opener=opener)
        self.assertEqual(len(releases), 101)
        self.assertEqual(seen, ['https://api.github.com/repos/EthDawg/workbench/releases?per_page=100&page=1',
                               'https://api.github.com/repos/EthDawg/workbench/releases?per_page=100&page=2'])

    def test_main_reads_a_saved_record_and_prints_json_without_the_network(self):
        with tempfile.TemporaryDirectory() as directory:
            saved = Path(directory) / 'releases.json'
            saved.write_text(json.dumps(RELEASES))
            output = io.StringIO()
            with redirect_stdout(output), patch.object(adoption, 'fetch_releases', side_effect=AssertionError('network used')):
                self.assertEqual(adoption.main(['--input', str(saved), '--json']), 0)
            payload = json.loads(output.getvalue())
            self.assertEqual(payload['releases'][0]['tag'], 'v2.4.0')
            self.assertTrue(payload['headline'].startswith('Workbench 2.4.0 has 8 archive downloads'))


if __name__ == '__main__':
    unittest.main()

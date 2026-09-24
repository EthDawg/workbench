import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { renderPublishedRelease, selectPublicRelease, validateRelease } from '../release.mjs';

// Synthetic records exercise selection only; they are never staged for publication.
const preview = {
  channel: 'preview', version: '2.1.0', tag: 'v2.1.0-preview.9', build: '9', source: 'a'.repeat(40), sha256: 'b'.repeat(64),
  download_url: 'https://github.com/EthDawg/workbench/releases/download/v2.1.0-preview.9/Workbench.Preview.zip'
};
const production = {
  ...preview, channel: 'production', tag: 'v2.1.0',
  download_url: 'https://github.com/EthDawg/workbench/releases/download/v2.1.0/Workbench.zip',
  feed_url: 'https://workbench-mac.vercel.app/updates/production.xml', feed_sha256: 'c'.repeat(64)
};

test('production takes precedence and an incomplete production record never falls back', () => {
  assert.equal(selectPublicRelease({ preview }).tag, preview.tag);
  assert.equal(selectPublicRelease({ preview, production }).tag, production.tag);
  assert.throws(() => selectPublicRelease({ preview }, { requireProduction: true }), /Production promotion requires/);
  for (const value of [null, {}, preview, { ...production, feed_url: undefined }]) {
    assert.throws(() => selectPublicRelease({ preview, production: value }), /Invalid published release/);
  }
});

test('release identity, digest and immutable links must agree', () => {
  for (const change of [
    { version: '2.0.0' }, { channel: 'preview' }, { channel: undefined }, { build: 'local' },
    { source: 'HEAD' }, { sha256: '' }, { feed_sha256: undefined },
    { download_url: preview.download_url }, { download_url: 'https://other.example/update.zip' },
    { feed_url: 'https://workbench-mac.vercel.app/updates/preview.xml' }
  ]) assert.throws(() => validateRelease({ ...production, ...change }), /Invalid published release/);
});

test('one receipt changes every current download and notes link together', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  const value = { ...preview, feed_url: 'https://workbench-mac.vercel.app/updates/preview.xml', feed_sha256: 'c'.repeat(64) };
  const result = renderPublishedRelease(html, value);
  assert.ok(result.includes(value.download_url));
  assert.ok(result.includes('/v2.1.0-preview.9/SHA256SUMS.txt'));
  assert.ok(result.includes('/tag/v2.1.0-preview.9'));
  assert.ok(result.includes('2.1.0 Preview 9'));
  assert.ok(result.includes('one-time manual installation'));
  assert.ok(result.includes('Automatic checks and background downloads are on by default'));
  assert.ok(result.includes('both can be changed in Settings, and existing choices are retained'));
  assert.ok(result.includes('normal Quit or when you explicitly restart an idle app'));
  assert.ok(result.includes('Active work defers an update-triggered restart'));
  assert.ok(result.includes('Versions without the updater need one manual replacement first'));
  assert.ok(!result.includes('no automatic updater'));
  const older = renderPublishedRelease(html, preview);
  assert.ok(older.includes('no automatic updater'));
  assert.ok(!older.includes('background downloads are on by default'));
  assert.ok(!older.includes('explicitly restart an idle app'));
  assert.ok(result.includes('same Applications folder'));
  assert.ok(!result.includes('{{'));
  assert.ok(!result.includes('value="2.0.0-preview.4"'));
});

test('production copy names Workbench and makes the Mac focus and separate data explicit', async () => {
  const html = renderPublishedRelease(await readFile(new URL('../index.html', import.meta.url), 'utf8'), production);
  assert.ok(html.includes(production.download_url));
  assert.ok(html.includes('<h3>Workbench</h3>'));
  assert.ok(html.includes('<strong>Workbench.app</strong>'));
  assert.ok(!html.includes('Workbench.Preview.zip'));
  assert.ok(!html.includes('Get Workbench Preview'));
  assert.ok(!html.includes('class="beta"'));
  assert.ok(!html.includes('href="/mobile/"'));
  assert.ok(!html.includes('EthDawg/StageMark/issues'));
  assert.ok(html.includes('Work on iPhone, iPad and the Chrome extension is paused'));
  assert.ok(html.includes('does not copy Preview data automatically'));
  assert.ok(html.includes('~/Library/Application Support/Workbench</code>'));
  assert.ok(!html.includes('{{'));
  assert.equal(renderPublishedRelease('{{PREVIEW_TAG}} {{PREVIEW_VERSION}}', production), 'v2.1.0 2.1.0');
  assert.throws(() => renderPublishedRelease('{{UNKNOWN_RELEASE}}', production), /Unknown release placeholder/);
});

test('feedback never substitutes website version for the installed build', async () => {
  const js = await readFile(new URL('../app.mjs', import.meta.url), 'utf8');
  assert.ok(!js.includes("getElementById('version').value = apps"));
});

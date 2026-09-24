import test from 'node:test';
import assert from 'node:assert/strict';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'workbench-site-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  // Exact source allowlist; never copy local environment or deployment files.
  for (const name of ['build.mjs', 'release.mjs', 'report.mjs', 'app.mjs', 'index.html', 'privacy.html', 'style.css', 'guide', 'mobile', 'handoff', 'scenes', 'personas', 'phone-presenting', 'handbook']) {
    await cp(new URL(`../${name}`, import.meta.url), join(directory, name), { recursive: true });
  }
  await mkdir(join(directory, 'assets'));
  await mkdir(join(directory, 'updates'));
  await writeFile(join(directory, 'updates/preview.json'), JSON.stringify({
    version: '2.0.0', build: '4', tag: 'v2.0.0-preview.4', source: 'a'.repeat(40), sha256: 'b'.repeat(64),
    download_url: 'https://github.com/EthDawg/workbench/releases/download/v2.0.0-preview.4/Workbench.Preview.zip'
  }));
  await writeFile(join(directory, '.env.local'), 'SYNTHETIC_PRIVATE_FIXTURE=not-for-public-output');
  await writeFile(join(directory, 'updates/maintainer-notes.txt'), 'Synthetic non-public notes');
  return directory;
}
function build(directory, ...options) {
  return spawnSync(process.execPath, [join(directory, 'build.mjs'), ...options], { encoding: 'utf8' });
}
async function stageSyntheticProduction(directory, { feed = true } = {}) {
  const xml = '<!-- Synthetic test fixture; no signing or publication claim. -->';
  const receipt = {
    channel: 'production', version: '2.1.0', build: '10', tag: 'v2.1.0', source: 'a'.repeat(40), sha256: 'b'.repeat(64),
    download_url: 'https://github.com/EthDawg/workbench/releases/download/v2.1.0/Workbench.zip',
    feed_url: 'https://workbench-mac.vercel.app/updates/production.xml',
    feed_sha256: createHash('sha256').update(xml).digest('hex')
  };
  await writeFile(join(directory, 'updates/production.json'), JSON.stringify(receipt));
  if (feed) await writeFile(join(directory, 'updates/production.xml'), xml);
  return receipt;
}

test('built HTML, browser feedback and update assets share the selected production record', async t => {
  const directory = await fixture(t);
  const receipt = await stageSyntheticProduction(directory);
  const result = build(directory, '--require-production');
  assert.equal(result.status, 0, result.stderr);
  const html = await readFile(join(directory, 'public/index.html'), 'utf8');
  const guide = await readFile(join(directory, 'public/guide/index.html'), 'utf8');
  assert.ok(html.includes(receipt.download_url));
  assert.ok(guide.includes(`/tag/${receipt.tag}`));
  assert.ok(!html.includes('{{'));
  assert.ok(!guide.includes('{{'));
  const { currentRelease } = await import(pathToFileURL(join(directory, 'public/release.mjs')));
  const { apps, agentHandoff } = await import(pathToFileURL(join(directory, 'public/report.mjs')));
  assert.deepEqual(currentRelease, receipt);
  assert.equal(apps.voice.version, receipt.version);
  assert.ok(agentHandoff().includes(`/tree/${receipt.tag}`));
  assert.ok(agentHandoff().includes('Source for this release:'));
  assert.ok(!agentHandoff().includes('Source for this Preview:'));
  assert.equal(await readFile(join(directory, 'public/updates/production.xml'), 'utf8'), await readFile(join(directory, 'updates/production.xml'), 'utf8'));
  for (const path of ['.env.local', 'updates/maintainer-notes.txt', 'updates/README.md', 'tests']) {
    await assert.rejects(access(join(directory, 'public', path)), { code: 'ENOENT' });
  }
});

test('legacy fallback is honest and cannot pass the explicit production promotion gate', async t => {
  const directory = await fixture(t);
  let result = build(directory);
  assert.equal(result.status, 0, result.stderr);
  const existing = await readFile(join(directory, 'public/index.html'), 'utf8');
  assert.ok(existing.includes('Workbench.Preview.zip'));
  assert.ok(existing.includes('no automatic updater'));
  result = build(directory, '--require-production');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Production promotion requires/);
  assert.equal(await readFile(join(directory, 'public/index.html'), 'utf8'), existing);
});

test('malformed, missing or changed production feed stops promotion before replacing output', async t => {
  const directory = await fixture(t);
  assert.equal(build(directory).status, 0);
  const existing = await readFile(join(directory, 'public/index.html'), 'utf8');
  await writeFile(join(directory, 'updates/production.json'), '{broken');
  assert.notEqual(build(directory).status, 0);
  await stageSyntheticProduction(directory, { feed: false });
  assert.match(build(directory).stderr, /ENOENT/);
  await writeFile(join(directory, 'updates/production.xml'), 'different synthetic bytes');
  assert.match(build(directory).stderr, /feed differs from the verified publication record/);
  assert.equal(await readFile(join(directory, 'public/index.html'), 'utf8'), existing);
});

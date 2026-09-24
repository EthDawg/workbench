import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { renderPublishedRelease, currentRelease } from '../release.mjs';
test('one receipt changes every current download and notes link together', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  const value = { ...currentRelease, version:'2.1.0', tag:'v2.1.0-preview.9', download_url:'https://github.com/EthDawg/workbench/releases/download/v2.1.0-preview.9/Workbench.Preview.zip', feed_url:'https://workbench-mac.vercel.app/updates/preview.xml' };
  const result = renderPublishedRelease(html, value);
  assert.ok(result.includes(value.download_url));
  assert.ok(result.includes('/v2.1.0-preview.9/SHA256SUMS.txt'));
  assert.ok(result.includes('/tag/v2.1.0-preview.9'));
  assert.ok(result.includes('2.1.0 Preview 9'));
  assert.ok(result.includes('one-time manual installation'));
  assert.ok(result.includes('automatic downloads are optional'));
  assert.ok(!result.includes('no automatic updater'));
  const older = renderPublishedRelease(html, { ...value, feed_url: undefined });
  assert.ok(older.includes('no automatic updater'));
  assert.ok(!older.includes('automatic downloads are optional'));
  assert.ok(result.includes('same Applications folder'));
  assert.ok(!result.includes('{{'));
  assert.ok(!result.includes('value="2.0.0-preview.4"'));
  assert.throws(()=>renderPublishedRelease(html, { ...value, download_url:'https://other.example/update.zip' }));
});
test('feedback never substitutes website version for the installed build', async()=>{
  const js=await readFile(new URL('../app.mjs',import.meta.url),'utf8');
  assert.ok(!js.includes("getElementById('version').value = apps"));
});

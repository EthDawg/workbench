import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { SITE_ORIGIN, DURABLE_ORIGIN, siteURL, pagePath, withCanonical } from '../origin.mjs';
import { validateContract, agentBrief } from '../handbook/render.mjs';

test('both addresses are bare HTTPS origins', () => {
  for (const origin of [SITE_ORIGIN, DURABLE_ORIGIN]) {
    const url = new URL(origin);
    assert.equal(url.protocol, 'https:');
    assert.equal(url.origin, origin, 'no path, query or trailing slash');
  }
});

test('the durable host is the one shipped builds already use', () => {
  // Compiled into released Mac, iOS and Chrome builds, the Sparkle feed base
  // and two store listings. Changing it strands every installed copy; read
  // HOSTING.md before touching this line.
  assert.equal(DURABLE_ORIGIN, 'https://workbench-mac.vercel.app');
});

test('every page answers on the path people link to, and names one canonical address', () => {
  assert.equal(pagePath('index.html'), '/');
  assert.equal(pagePath('guide/index.html'), '/guide/');
  assert.equal(pagePath('scenes/ambient/index.html'), '/scenes/ambient/');
  assert.equal(pagePath('privacy.html'), '/privacy.html');
  const html = withCanonical('<html><head><title>Guide</title>\n</head><body></body></html>', '/guide/');
  assert.ok(html.includes(`<link rel="canonical" href="${SITE_ORIGIN}/guide/">`));
  assert.throws(() => withCanonical(html, '/guide/'), /already declares/);
  assert.throws(() => withCanonical('<p>no head</p>', '/'), /exactly one/);
});

test('the handbook names its own pages by path and publishes them at the site address', async () => {
  const raw = JSON.parse(await readFile(new URL('../handbook/contract.json', import.meta.url), 'utf8'));
  const own = raw.sources.filter(source => source.url.startsWith('/'));
  assert.ok(own.length >= 2, 'scenes and phone-presenting are site pages');
  const contract = validateContract(raw);
  for (const source of contract.sources) assert.match(source.url, /^https:\/\//);
  assert.ok(contract.sources.some(source => source.url === siteURL('/scenes/')));
  assert.ok(agentBrief(contract).includes(`Canonical record: ${siteURL('/handbook/contract.json')}`));
});

test('only origin.mjs names a website address', async () => {
  // Moving the site stays a one-line change. Release data under updates/ is
  // exempt by design: the feed belongs to the durable host.
  const hosts = /workbench-mac\.vercel\.app|workbench\.mwdm\.cloud/;
  const root = new URL('../', import.meta.url);
  const exempt = /^(origin\.mjs|README\.md|HOSTING\.md|tests\/|updates\/|public\/|\.vercel\/)/;
  const offenders = [];
  for (const file of await readdir(root, { recursive: true })) {
    if (exempt.test(file) || !/\.(mjs|js|html|css|json|txt)$/.test(file)) continue;
    if (hosts.test(await readFile(new URL(file, root), 'utf8'))) offenders.push(file);
  }
  assert.deepEqual(offenders, [], 'import SITE_ORIGIN or DURABLE_ORIGIN from origin.mjs instead');
});

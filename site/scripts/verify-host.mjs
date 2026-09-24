#!/usr/bin/env node
// Check that a live host serves the site this checkout builds, with the
// headers vercel.json promises. HOSTING.md uses it at every cutover step.
//
//   node site/build.mjs && node site/scripts/verify-host.mjs [origin]
//   node site/scripts/verify-host.mjs <origin> --same-as <other origin>
//   node site/scripts/verify-host.mjs --promises
//
// [origin] defaults to SITE_ORIGIN, or DURABLE_ORIGIN with --promises.
// HOSTING.md gives the exact command for each cutover step.
//
// Default: every built file answers 200 directly, carries its configured
// headers, and every page names the same single canonical address.
// --same-as: a second host serves byte-identical files (one deployment, two names).
// --promises: only what installed apps and store listings depend on, on the
//   durable host: the privacy policy and every signed feed, never redirected.
import { readFile, readdir, stat } from 'node:fs/promises';
import { SITE_ORIGIN, DURABLE_ORIGIN, pagePath } from '../origin.mjs';

const args = process.argv.slice(2);
const flag = name => args.includes(name);
const option = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const promises = flag('--promises');
const other = option('--same-as');
const origin = args.find((value, i) => /^https:\/\//.test(value) && args[i - 1] !== '--same-as') ?? (promises ? DURABLE_ORIGIN : SITE_ORIGIN);
const site = new URL('../', import.meta.url);

const config = JSON.parse(await readFile(new URL('vercel.json', site), 'utf8'));
const pattern = source => new RegExp('^' + source.split('(.*)').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
const expected = path => Object.fromEntries(config.headers.filter(rule => pattern(rule.source).test(path)).flatMap(rule => rule.headers.map(h => [h.key.toLowerCase(), h.value])));

async function paths() {
  if (promises) {
    const feeds = (await readdir(new URL('updates/', site))).filter(name => name.endsWith('.xml')).map(name => `/updates/${name}`);
    return ['/privacy.html', ...feeds];
  }
  const files = await readdir(new URL('public/', site), { recursive: true }).catch(() => { throw new Error('Run node site/build.mjs first: this compares a host with the local build.'); });
  const built = [];
  for (const file of files) if ((await stat(new URL(`public/${file}`, site))).isFile()) built.push(pagePath(file));
  return built.sort();
}

async function check(path) {
  const problems = [];
  const response = await fetch(origin + path, { redirect: 'manual' });
  if (response.status !== 200) return { path, problems: [`${response.status}${response.headers.get('location') ? ' to ' + response.headers.get('location') : ''}`] };
  const body = Buffer.from(await response.arrayBuffer());
  for (const [key, value] of Object.entries(expected(path))) {
    if (response.headers.get(key) !== value) problems.push(`${key} is ${JSON.stringify(response.headers.get(key))}`);
  }
  // Canonical links are the site's concern, not a promise to apps or stores.
  const page = !promises && (path.endsWith('/') || path.endsWith('.html'));
  const canonicals = page ? [...body.toString('utf8').matchAll(/<link rel="canonical" href="([^"]+)">/g)].map(m => m[1]) : [];
  if (page && canonicals.length !== 1) problems.push(`${canonicals.length} canonical links`);
  if (other) {
    const twin = await fetch(other + path, { redirect: 'manual' });
    if (twin.status !== 200) problems.push(`${other} answers ${twin.status}`);
    else if (!body.equals(Buffer.from(await twin.arrayBuffer()))) problems.push(`differs from ${other}`);
  }
  return { path, problems, canonical: canonicals[0] && new URL(canonicals[0]).origin };
}

// A host that does not resolve yet, or refuses TLS, is a result, not a crash.
const attempt = path => check(path).catch(error => ({ path, problems: [`no answer (${error.cause?.code ?? error.message})`] }));
const list = await paths();
const results = [];
for (let i = 0; i < list.length; i += 8) results.push(...await Promise.all(list.slice(i, i + 8).map(attempt)));
const failed = results.filter(result => result.problems.length);
for (const result of failed) console.log(`✗ ${result.path}  ${result.problems.join('; ')}`);
const canonical = [...new Set(results.map(result => result.canonical).filter(Boolean))];
if (canonical.length > 1) { console.log(`✗ pages disagree on their canonical address: ${canonical.join(', ')}`); failed.push({}); }
console.log(`${failed.length ? '✗' : '✓'} ${origin}: ${results.length - failed.length} of ${results.length} ${promises ? 'promises kept' : 'files as built'}` +
  (canonical.length === 1 ? `, canonical ${canonical[0]}` : '') + (other ? `, identical to ${other}` : ''));
process.exitCode = failed.length ? 1 : 0;

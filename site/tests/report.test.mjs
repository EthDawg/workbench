import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { renderPublishedRelease } from '../release.mjs';
import { apps, createReport, agentHandoff } from '../report.mjs';
const input = { app:'voice',version:'1.2.1',environment:'M2, macOS 26',task:'Copy a capture & preserve “café”',expected:'The original words',observed:'Different text\nSecond line',impact:'Small friction',help:'I can test a fix' };
test('routes both Workbench areas to the unified repository and preserves feedback through URL encoding',()=>{
  for(const [app,repo] of [['voice','workbench'],['stagemark','workbench']]){
    const report=createReport({...input,app});const url=new URL(report.url);
    assert.equal(url.origin,'https://github.com');assert.equal(url.pathname,`/EthDawg/${repo}/issues/new`);
    assert.equal(url.searchParams.get('body'),report.body);assert.match(report.body,/“café”/);assert.match(report.body,/Different text\nSecond line/);
    assert.equal(url.searchParams.get('labels'),'user feedback');
  }
});
test('rejects invalid destinations and incomplete observations',()=>{
  assert.throws(()=>createReport({...input,app:'__proto__'}));
  assert.throws(()=>createReport({...input,app:'https://evil.example'}));
  for(const field of ['version','environment','task','expected','observed']) assert.throws(()=>createReport({...input,[field]:'  '}));
});
test('agent handoff carries evidence and avoids inventing native verification',()=>{
  const report=createReport(input);const handoff=agentHandoff(report);
  assert.ok(handoff.includes(report.body));assert.match(handoff,/Do not claim observations or test results you did not verify/);
  assert.ok(handoff.includes(`https://github.com/EthDawg/workbench/tree/v${apps.voice.version}`));
  assert.ok(handoff.includes(`https://github.com/EthDawg/workbench/blob/v${apps.voice.version}/docs/workbench.md`));
  assert.ok(handoff.includes(apps.voice.guide));
  assert.match(agentHandoff(),/small unassigned good first issue/);
});
test('bounds long reports without silently truncating observations',()=>{
  assert.throws(()=>createReport({...input,observed:'x'.repeat(1501)}));
  const report=createReport({...input,observed:'x'.repeat(1500)});assert.ok(report.body.includes('x'.repeat(1500)));
});

test('download versions and in-page destinations remain consistent',async()=>{
  const html=renderPublishedRelease(await readFile(new URL('../index.html',import.meta.url),'utf8'));
  for(const app of Object.values(apps)){
    assert.ok(html.includes(`https://github.com/EthDawg/${app.repo}/releases/tag/v${app.version}`));
    assert.ok(html.includes(`https://github.com/EthDawg/${app.repo}/releases/download/v${app.version}/SHA256SUMS.txt`));
    assert.ok(html.includes(app.guide));
  }
  for(const match of html.matchAll(/href="#([^" ]+)"/g)) assert.ok(html.includes(`id="${match[1]}"`),`Missing anchor ${match[1]}`);
});

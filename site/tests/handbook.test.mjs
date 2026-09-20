import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateContract, renderHandbook, agentBrief } from '../handbook/render.mjs';
const contract = JSON.parse(await readFile(new URL('../handbook/contract.json', import.meta.url), 'utf8'));
const template = await readFile(new URL('../handbook/index.html', import.meta.url), 'utf8');

test('human and agent views preserve every capability status and evidence boundary', () => {
  const html = renderHandbook(template, contract), brief = agentBrief(contract);
  for (const item of contract.capabilities) {
    assert.ok(html.includes(`id="${item.id}"`));
    assert.ok(brief.includes(`${item.id} [${item.status}]`));
    assert.ok(brief.includes(item.limit));
  }
  for (const item of contract.events) for (const key of ['stops', 'keeps', 'check']) assert.ok(brief.includes(item[key]));
  for (const item of contract.acceptance) assert.ok(brief.includes(item.test));
  assert.equal(contract.capabilities.find(item=>item.id==='wallpaper-motion').status,'implemented');
  assert.equal(contract.capabilities.find(item=>item.id==='wallpaper-entry').status,'proposed');
  assert.ok(!/<!-- [A-Z_]+ -->/.test(html));
});
test('contract rejects ambiguous IDs and unsupported status instead of silently publishing them', () => {
  const duplicate = structuredClone(contract); duplicate.events.push(duplicate.events[0]);
  assert.throws(()=>validateContract(duplicate), /duplicate/);
  const status = structuredClone(contract); status.capabilities[0].status='released-everywhere';
  assert.throws(()=>validateContract(status), /Unknown status/);
});
test('rendered records escape contributed text and source links stay repository relative', () => {
  const unsafe = structuredClone(contract); unsafe.capabilities[0].name='<img src=x onerror=alert(1)>';
  const html=renderHandbook(template,unsafe);
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'));
  assert.ok(!html.includes('<img src=x onerror=alert(1)>'));
  for (const item of contract.capabilities) assert.match(item.source, /^(Sources\/StageKit\/[A-Za-z]+\.swift|docs\/[a-z-]+\.md)$/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { packLink } from '../packs/open.mjs';
test('pack link keeps repository in fragment and requires explicit open', () => {
  assert.deepEqual(packLink('#source=company%2Fpack'), { source: 'company/pack', url: 'workbench://packs/add?source=https%3A%2F%2Fgithub.com%2Fcompany%2Fpack' });
});
test('pack link refuses credentials, traversal and extra parameters', () => {
  for (const value of ['#source=token@github.com/a/b','#source=a/../b','#source=a/b&source=evil/repo','#source=https://evil.test/a/b','#source=a/b&token=secret']) assert.equal(packLink(value), null);
});

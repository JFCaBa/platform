import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadRecents, addRecent } from '../js/recents.js';

const mem = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) }; };

test('max 5, newest first, re-adding moves to front', () => {
  const s = mem();
  for (const c of ['AAA', 'BBB', 'CCC', 'DDD', 'EEE', 'FFF']) addRecent(s, { crs: c, name: c });
  assert.deepEqual(loadRecents(s).map((r) => r.crs), ['FFF', 'EEE', 'DDD', 'CCC', 'BBB']);
  const out = addRecent(s, { crs: 'DDD', name: 'DDD' });
  assert.deepEqual(out.map((r) => r.crs), ['DDD', 'FFF', 'EEE', 'CCC', 'BBB']);
  assert.deepEqual(loadRecents(s), out);
});

test('no storage, throwing storage, corrupt data', () => {
  assert.deepEqual(loadRecents(null), []);
  assert.deepEqual(addRecent(null, { crs: 'KGX', name: 'K' }).map((r) => r.crs), ['KGX']);
  const bad = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); } };
  assert.deepEqual(loadRecents(bad), []);
  assert.doesNotThrow(() => addRecent(bad, { crs: 'KGX', name: 'K' }));
  const s = mem(); s.setItem('recents', '{not json');
  assert.deepEqual(loadRecents(s), []);
  s.setItem('recents', JSON.stringify([{ crs: 'KGX', name: 'K' }, { nope: 1 }, 'x']));
  assert.deepEqual(loadRecents(s).map((r) => r.crs), ['KGX']);
});

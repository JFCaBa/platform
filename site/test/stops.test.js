import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stopsNeedFetch } from '../js/stops.js';

test('stopsNeedFetch: missing, failed or older than 30 s; not while loading', () => {
  const now = 1_000_000;
  assert.equal(stopsNeedFetch(undefined, now), true);
  assert.equal(stopsNeedFetch({ state: 'error', at: now - 1000 }, now), true);
  assert.equal(stopsNeedFetch({ state: 'ok', portions: [], at: now - 10_000 }, now), false);
  assert.equal(stopsNeedFetch({ state: 'ok', portions: [], at: now - 31_000 }, now), true);
  assert.equal(stopsNeedFetch({ state: 'loading', pending: true, at: now - 60_000 }, now), false);
  assert.equal(stopsNeedFetch({ state: 'ok', portions: [], pending: true, at: now - 60_000 }, now), false);
});

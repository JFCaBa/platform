import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseRoute } from '../js/route.js';

test('parseRoute', () => {
  assert.deepEqual(parseRoute('/'), { page: 'home' });
  assert.deepEqual(parseRoute('/station/KGX'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  assert.deepEqual(parseRoute('/station/kgx'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  assert.deepEqual(parseRoute('/station/KGX/'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  for (const p of ['/station/KG', '/station/KGXX', '/foo', '/station/', '/station/K1X']) {
    assert.deepEqual(parseRoute(p), { page: 'notfound' }, p);
  }
});

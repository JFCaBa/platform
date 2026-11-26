import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseRoute, extraBelongs } from '../js/route.js';

test('parseRoute', () => {
  assert.deepEqual(parseRoute('/'), { page: 'home' });
  assert.deepEqual(parseRoute('/station/KGX'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  assert.deepEqual(parseRoute('/station/kgx'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  assert.deepEqual(parseRoute('/station/KGX/'), { page: 'station', crs: 'KGX', canonical: '/station/KGX' });
  for (const p of ['/station/KG', '/station/KGXX', '/foo', '/station/', '/station/K1X']) {
    assert.deepEqual(parseRoute(p), { page: 'notfound' }, p);
  }
});

test('extraBelongs: the static aside stays only on the page it was built for', () => {
  assert.equal(extraBelongs('/station/EUS', '/station/EUS'), true);
  assert.equal(extraBelongs('/station/EUS', '/station/EUS/'), true);
  assert.equal(extraBelongs('/station/EUS', '/station/eus'), true);
  assert.equal(extraBelongs('/station/EUS', '/station/KGX'), false);
  assert.equal(extraBelongs('/', '/'), true);
  assert.equal(extraBelongs('/', '/station/EUS'), false);
  assert.equal(extraBelongs('/station/EUS', '/'), false);
  assert.equal(extraBelongs(undefined, '/'), false);
});

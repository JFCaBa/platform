import { test } from 'node:test';
import assert from 'node:assert/strict';
import { apiBase, fetchJson, ApiError } from '../js/api.js';

test('apiBase', () => {
  assert.equal(apiBase('whatplatform.uk'), 'https://api.whatplatform.uk');
  assert.equal(apiBase('localhost'), '');
  assert.equal(apiBase('127.0.0.1'), '');
});

const res = (status, body) => async () => ({ ok: status >= 200 && status < 300, status, text: async () => body });
const kind = async (impl) => {
  try { await fetchJson('/x', impl); return 'ok'; } catch (e) { assert.ok(e instanceof ApiError); return e.kind; }
};

test('fetchJson: JSON on 200, error kinds otherwise', async () => {
  assert.deepEqual(await fetchJson('/x', res(200, '{"a":1}')), { a: 1 });
  assert.equal(await kind(res(404, '{}')), 'notfound');
  assert.equal(await kind(res(429, '')), 'ratelimited');
  assert.equal(await kind(res(502, '')), 'unavailable');
  assert.equal(await kind(res(200, '<html>')), 'unavailable');
  assert.equal(await kind(async () => { throw new TypeError('Failed to fetch'); }), 'network');
});

test('fetchJson: an aborted request rethrows the AbortError', async () => {
  const abort = async () => { throw new DOMException('aborted', 'AbortError'); };
  await assert.rejects(fetchJson('/x', abort), { name: 'AbortError' });
});

test('fetchJson: a request that never answers times out as network', async () => {
  const hang = (url, { signal }) => new Promise((_, reject) =>
    signal.addEventListener('abort', () => reject(signal.reason ?? new DOMException('aborted', 'AbortError'))));
  const t0 = Date.now();
  await assert.rejects(fetchJson('/x', hang, undefined, 50), (e) => e instanceof ApiError && e.kind === 'network');
  assert.ok(Date.now() - t0 < 1000);
});

test('fetchJson: the caller aborting still rethrows AbortError, not a timeout', async () => {
  const hang = (url, { signal }) => new Promise((_, reject) =>
    signal.addEventListener('abort', () => reject(signal.reason ?? new DOMException('aborted', 'AbortError'))));
  const c = new AbortController();
  setTimeout(() => c.abort(), 10);
  await assert.rejects(fetchJson('/x', hang, c.signal, 5000), { name: 'AbortError' });
});

// The What Platform API. On localhost the dev server (deploy/web/dev.py) proxies it, same origin.

export const apiBase = (hostname) =>
  hostname === 'localhost' || hostname === '127.0.0.1' ? '' : 'https://api.whatplatform.uk';

export class ApiError extends Error {
  /** @param {'notfound'|'ratelimited'|'unavailable'|'network'} kind */
  constructor(kind, status = 0) {
    super(`api ${kind}${status ? ` (${status})` : ''}`);
    this.kind = kind;
    this.status = status;
  }
}

/** GET `url` as JSON. Throws ApiError, or the AbortError of an aborted request. */
export async function fetchJson(url, fetchImpl = fetch, signal) {
  let r;
  try {
    r = await fetchImpl(url, { signal });
  } catch (e) {
    if (e?.name === 'AbortError') throw e;
    throw new ApiError('network');
  }
  if (r.status === 404) throw new ApiError('notfound', 404);
  if (r.status === 429) throw new ApiError('ratelimited', 429);
  if (!r.ok) throw new ApiError('unavailable', r.status);
  try {
    return JSON.parse(await r.text());
  } catch {
    throw new ApiError('unavailable', r.status);
  }
}

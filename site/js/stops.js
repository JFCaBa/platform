// A train's stops (/service/{id}), cached per train while its station is open. Entries:
// {state: 'loading' | 'ok' | 'error', portions?, at (ms), pending?}. Estimates change, so an
// entry older than the board's refresh is fetched again; a failed one is retried.
export const STOPS_MAX_AGE_MS = 30_000;

export function stopsNeedFetch(entry, nowMs) {
  if (!entry) return true;
  if (entry.pending) return false;
  return entry.state === 'error' || nowMs - entry.at > STOPS_MAX_AGE_MS;
}

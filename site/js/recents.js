// Recent stations, newest first, in this browser's localStorage. Storage may be missing or
// throw (private mode, blocked): then there are simply no recents.
const KEY = 'recents';
const MAX = 5;

const valid = (r) => r && typeof r === 'object' && typeof r.crs === 'string' && typeof r.name === 'string';

export function loadRecents(storage) {
  try {
    const list = JSON.parse(storage?.getItem(KEY) ?? '[]');
    return Array.isArray(list) ? list.filter(valid).slice(0, MAX).map(({ crs, name }) => ({ crs, name })) : [];
  } catch {
    return [];
  }
}

/** Puts `station` first and returns the new list (saved when storage works). */
export function addRecent(storage, station) {
  const list = [{ crs: station.crs, name: station.name },
    ...loadRecents(storage).filter((r) => r.crs !== station.crs)].slice(0, MAX);
  try {
    storage?.setItem(KEY, JSON.stringify(list));
  } catch {
    // storage blocked: keep the list for this page only
  }
  return list;
}

// Stations: nearest (app/lib/domain/nearest.dart), search, distance text (app/lib/ui/format.dart).

export function haversineMeters(lat1, lon1, lat2, lon2) {
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}

/** Closest station in a straight line: {station, meters}. `stations` must not be empty. */
export function nearestStation(stations, lat, lon) {
  let station = null, meters = Infinity;
  for (const s of stations) {
    const m = haversineMeters(lat, lon, s.lat, s.lon);
    if (m < meters) { station = s; meters = m; }
  }
  return { station, meters };
}

const norm = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/['’.]/g, '').replace(/[-/(),&]+/g, ' ').replace(/\s+/g, ' ').trim();

/** Up to `limit` stations: exact CRS, then name prefix, then a word prefix, then substring. */
export function searchStations(stations, query, limit = 8) {
  const q = norm(query ?? '');
  if (!q) return [];
  const crsQ = q.toUpperCase();
  const scored = [];
  for (const s of stations) {
    const name = norm(s.name);
    let rank = null;
    if (s.crs === crsQ) rank = 0;
    else if (name.startsWith(q)) rank = 1;
    else if ((' ' + name).includes(' ' + q)) rank = 2;
    else if (name.includes(q)) rank = 3;
    if (rank != null) scored.push({ s, rank });
  }
  scored.sort((a, b) => a.rank - b.rank || a.s.name.localeCompare(b.s.name));
  return scored.slice(0, limit).map((x) => x.s);
}

export const formatDistance = (m) =>
  m < 1000 ? `${Math.round(m / 10) * 10} m` : m < 100000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m / 1000)} km`;

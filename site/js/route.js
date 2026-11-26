// URL → page: "/" home, "/station/KGX" (any case, optional trailing slash) a station.

export function parseRoute(pathname) {
  if (pathname === '/' || pathname === '') return { page: 'home' };
  const m = /^\/station\/([A-Za-z]{3})\/?$/.exec(pathname);
  if (!m) return { page: 'notfound' };
  const crs = m[1].toUpperCase();
  return { page: 'station', crs, canonical: `/station/${crs}` };
}

// The server-built <aside id="extra" data-path="…"> (nearby stations, A–Z link) belongs to one
// page: after in-app navigation to another page it would be stale.
export function extraBelongs(dataPath, pathname) {
  if (!dataPath) return false;
  const here = parseRoute(pathname);
  const mine = parseRoute(dataPath);
  if (here.page !== mine.page) return false;
  return here.page !== 'station' || here.crs === mine.crs;
}

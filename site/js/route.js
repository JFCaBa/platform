// URL → page: "/" home, "/station/KGX" (any case, optional trailing slash) a station.

export function parseRoute(pathname) {
  if (pathname === '/' || pathname === '') return { page: 'home' };
  const m = /^\/station\/([A-Za-z]{3})\/?$/.exec(pathname);
  if (!m) return { page: 'notfound' };
  const crs = m[1].toUpperCase();
  return { page: 'station', crs, canonical: `/station/${crs}` };
}

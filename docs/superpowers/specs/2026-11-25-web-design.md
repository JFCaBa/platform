# What Platform on the web (whatplatform.uk)

Date: 25-11-2026. Status: approved by the user (25-11-2026).

## Intent

A website at `https://whatplatform.uk` that works as much as possible like the What Platform app (the
next National Rail departures at a station, with the platform, delays and cancellations), with the
App Store badge visible from the first screen. Model: https://www.platformfinder.co.uk/ — a sparse
home (headline, station search, popular stations) and one page per station (`/station/EUS`) with the
live board. Same KISS criterion as the rest of the project.

Why: people who search for "which platform" on the web get the board straight away, and the site
sends them to the App Store for what only the app can do (following a train).

## Goals

- Home page `/`: headline, one-line tagline, **App Store badge**, «Use my location» button, station
  search, recent stations (this browser), popular stations grid, footer.
- Station page `/station/{CRS}`: the app's board for that station, refreshed while visible.
- Board, as in the app (`app/lib/ui/home_screen.dart`, `departure_row.dart`):
  - header: station name, distance if located, «Live · hh:mm:ss» from `generatedAt`;
  - service alerts line (`nrccMessages`): «N service alert(s)», tap to expand;
  - destination filter chips («All» + destinations);
  - first train as a large card (destination, platform, minutes to go / «Cancelled» / «Delayed»,
    scheduled + expected, via, operator, reasons), the rest as rows;
  - tap a train → its remaining stops (one train open at a time), «Stops unavailable» on error;
  - «Show more» (later offsets, as the app: multiples of 15 plus 119), with the app's end texts
    («No more departures in the next 4 hours» / «That's as far ahead as we can show»);
  - empty texts: «No departures in the next 2 hours», «No trains to these destinations right now»;
  - error banner with «Retry»;
  - attribution («Data: National Rail») and Privacy link.
- In place of «Follow this train» in the stops panel: «Get alerts if your platform changes —
  download the app» linking to the App Store.
- The privacy policy keeps working at `/privacy` (today's `site/index.html` moves to
  `site/privacy.html`), updated for the website.

## Non-goals

- No Google Play badge for now (Android is in closed testing); add it when it goes to production.
- No following, push, widgets or Live Activities on the web.
- No server-side rendering of station pages (approach 2 below), no sitemap for now.
- Nothing for Andén: its web and domain are a later topic.

## Anti-goals

- No frameworks, bundlers, npm, build step, cookies, analytics scripts, third-party fonts or CDNs.
- No asking for location on page load: only when the user presses «Use my location».
- The web must not change what the installed apps get from the API.

## Approaches

1. **Static single page with plain JavaScript (chosen by the user).** nginx serves one
   `index.html` for `/` and `/station/XXX`; `app.js` reads the URL, fetches from the API and draws
   the page. Few files, no build, deployed with `git pull` like today. Google must run the JS to see
   each station (it does, less well than with plain HTML).
2. Station HTML rendered by the Python API: best for search engines, but the API grows and needs
   templates. Possible later without throwing away (1).
3. Flutter web build of the app: identical to the app, but several MB, poor in mobile browsers,
   barely indexable. Not KISS.

## Design

### Files (platform repo, `site/`)

- `index.html` — shell for home and station pages; `<noscript>` text.
- `app.js` — routing, data, rendering, refresh, location, recents (one file, ES module or plain).
- `style.css` — the app's look (panel style: dark background, amber delays, red cancellations),
  light and dark via `prefers-color-scheme`, mobile first.
- `privacy.html` — today's `index.html`, plus a website section (below).
- `app-store-badge.svg` — Apple's official black «Download on the App Store» badge (en-GB) from
  Apple's marketing tools, unmodified, per Apple's badge guidelines. Link:
  `https://apps.apple.com/gb/app/what-platform/id6835503942`.
- Favicon from the app icon.
- `privacy.html` uses `style.css` (no inline `<style>`: the new CSP has no `'unsafe-inline'`).

### Deploy order *(settled)*

Commit adds the new files and keeps `index.html` serving the privacy text until the same deploy
copies the nginx conf: `git pull` then `nginx -t` + reload in one command, so `/privacy` is wrong
for at most a second.

### Routing (nginx, `whatplatform.uk` server)

- `= /` and `~ ^/station/[A-Za-z]{3}$` → `index.html`.
- `~ ^/privacy/?$` → `privacy.html`.
- Static files (`app.js`, `style.css`, svg, icon) as files; anything else 404.
- Lower case: the JS normalises it (`/station/kgx` → `location.replace('/station/KGX')`). A code
  not in `stations.json` shows «Station not found» with the search.
- CSP: `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self';
  connect-src https://api.whatplatform.uk; base-uri 'none'; form-action 'none';
  frame-ancestors 'none'`. Other headers as today.

### Data

The browser calls the existing API at `https://api.whatplatform.uk` directly:
`/stations.json` (2,627 stations: `crs`, `name`, `lat`, `lon`), `/departures/{CRS}`,
`/departures/{CRS}/{OFFSET}`, `/service/{id}`. Shapes: as the app parses them
(`app/lib/data/departures.dart`).

- CORS: those four locations add `Access-Control-Allow-Origin: https://whatplatform.uk` (a fixed
  value, so no `Vary: Origin`). Plain GETs with no custom headers, so no preflight.
- The API's nginx cache is shared with the app: the web adds no Darwin calls beyond its own boards.
- Browsers pass the bad-bot User-Agent filter; nothing to change there. The web server's
  `snippets/honeypot.conf` only traps scanner paths (`.env`, `.git`, `wp-admin`, `phpinfo.php`…),
  none of the site's.
- *(Builder's call, settled)* The CORS header uses `always`, so the JS can read 404/429/5xx and
  the `return 400` answers too.
- *(Builder's call, settled)* A station in `stations.json` that the API answers 404 for: error
  banner «Departures unavailable for this station» with «Retry».

### Refresh

Every 30 s while the tab is visible (`visibilitychange`), as the app; on return to the tab, refresh
at once if older than 30 s. Pages already loaded by «Show more» are not refetched on every tick
(as the app does).

### Location

«Use my location» → `navigator.geolocation.getCurrentPosition` → nearest station from
`stations.json` (same haversine as `app/lib/domain/nearest.dart`) → `/station/{CRS}`, with the
distance shown in the header. Denied or unavailable: a short message and the search.

### Search and recents

Search over `stations.json` by name and CRS (case and accent insensitive, prefix of any word first),
up to 8 suggestions, keyboard and touch. Recents: the last 5 stations in `localStorage` (try/catch:
works without it). Popular stations (fixed list, as platformfinder): EUS, KGX, PAD, VIC, WAT, LST,
LBG, STP, CHX, MYB, BHM, MAN.

### Page titles

`<title>` and `<meta name="description">` set per station by the JS:
«London Kings Cross (KGX) — live departures and platforms | What Platform».

### Stats (`/admin`)

Web requests already reach the stats receiver (same nginx locations). Today only User-Agents starting
with `WhatPlatform/` count as people; browsers count as requests under version «otro». Change: a
browser User-Agent (`Mozilla/`) counts as a person too (same daily-keyed hash, never stored) and
appears as version **«web»** in the versions table, unless the UA matches
`bot|crawl|spider|preview|headless` (case-insensitive): those stay «otro» and are not people
*(builder's call, settled)*. Other UAs stay «otro» and are not people.

### Privacy policy

New section «The website»: what the browser asks our server (station codes, train ids, the station
list), that location is used only in the browser to find the nearest station and never sent, that
recent stations stay in this browser's local storage, no cookies, the anonymous daily count as for
the app.

### Tests

- `site/` JS: the pure parts (nearest station, search ranking, minutes-to-go and status texts,
  route parsing) in plain functions, tested with Node's built-in test runner (`node --test`), no
  dependencies. Rendering is checked by hand in a browser (desktop and phone width).
- API: stats test for «web» people/version.
- nginx: `nginx -t` and curl checks after deploy (routes, 404s, CSP, CORS header).

## Left to the builder

Exact markup and CSS, the ES-module split inside `app.js`, empty/error copy not listed above
(follow the app's), the favicon sizes.

// What Platform on the web: home (search, location, popular stations) and /station/{CRS} boards.
// Same behaviour as the app's home screen (app/lib/ui/home_screen.dart), minus following.
import { apiBase, fetchJson, ApiError, validBoard, validStations } from './api.js';
import { parseRoute } from './route.js';
import { stopsNeedFetch } from './stops.js';
import { loadRecents, addRecent } from './recents.js';
import { nearestStation, searchStations, formatDistance } from './stations.js';
import { mergeServices, contiguousPages, freshPages, trainKey, startIn, endIn, nextOffset, coveredEnd, OFFSET_STEP } from './pages.js';
import {
  isCancelled, statusText, isLate, nextTrainIndex, minutesUntilDeparture, waitText, londonMinutesUntil, londonHhmm,
} from './text.js';

const API = apiBase(location.hostname);
const APP_STORE = 'https://apps.apple.com/gb/app/what-platform/id6835503942';
const REFRESH_MS = 30_000;
const CLOCK_MS = 15_000;
const STALE_MS = 2 * 60_000; // as the app: older boards show "Last updated"
const EXPIRE_MS = 10 * 60_000; // too old to show trains
const RATE_LIMIT_MS = 5 * 60_000; // the app's rateLimitBackoff
const POPULAR = [
  ['EUS', 'London Euston'], ['KGX', 'London Kings Cross'], ['PAD', 'London Paddington'], ['VIC', 'London Victoria'],
  ['WAT', 'London Waterloo'], ['LST', 'London Liverpool Street'], ['LBG', 'London Bridge'],
  ['STP', 'London St Pancras International'], ['CHX', 'London Charing Cross'], ['MYB', 'London Marylebone'],
  ['BHM', 'Birmingham New Street'], ['MAN', 'Manchester Piccadilly'],
];

const root = document.getElementById('app');
const storage = (() => { try { return window.localStorage; } catch { return null; } })();

// ---- state ------------------------------------------------------------------------------------
let stationsPromise = null;
let stations = null; // [{crs, name, lat, lon}] once loaded
let located = null; // {crs, meters} from «Use my location», this page session only
let gen = 0; // bumped on every navigation: answers from an older one are dropped
let abort = new AbortController();
let refreshTimer = null;
let clockTimer = null;
let s = null; // station page state
let searchActive = null; // CRS highlighted in the suggestions, kept across re-renders

const freshStation = (crs) => ({
  crs, board: null, pages: [], failed: null, loading: true, loadingMore: false, stalledUntil: 0,
  rateLimitedUntil: 0, filters: new Set(), openSid: null, stops: new Map(), alertsOpen: false, unknown: false,
  moreFailed: false,
});

function loadStations() {
  stationsPromise ??= fetchJson(`${API}/stations.json`)
    .then((j) => { if (!validStations(j)) throw new ApiError('unavailable'); return (stations = j.stations); })
    .catch(() => { stationsPromise = null; return null; });
  return stationsPromise;
}

const nameOf = (crs) => stations?.find((x) => x.crs === crs)?.name ?? POPULAR.find(([c]) => c === crs)?.[1] ?? null;

// ---- DOM helper -------------------------------------------------------------------------------
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid);
  return el;
}

/** Replaces the page content; null/false children are skipped, arrays flattened. Focus survives:
 * the element with the same data-key (a train, a chip, «Show more»…) or the search box, with its
 * text and caret, gets it back — the clock re-renders the station page every 15 s. */
function put(...kids) {
  const el = document.activeElement;
  const key = el?.dataset?.key;
  const typing = el?.matches?.('.search input') ? { value: el.value, pos: el.selectionStart } : null;
  root.replaceChildren(...kids.flat(Infinity).filter((k) => k != null && k !== false));
  if (typing) {
    const input = root.querySelector('.search input');
    if (!input) return;
    input.value = typing.value;
    input.focus({ preventScroll: true });
    input.setSelectionRange(typing.pos, typing.pos);
    if (typing.value) input.dispatchEvent(new Event('input'));
  } else if (key) {
    [...root.querySelectorAll('[data-key]')].find((x) => x.dataset.key === key)?.focus({ preventScroll: true });
  }
}

const badge = (small = false) => h('a', { class: small ? 'badge small' : 'badge', href: APP_STORE, rel: 'noopener' },
  h('img', { src: '/app-store-badge.svg', alt: 'Download on the App Store', width: small ? 102 : 132, height: small ? 34 : 44 }));

const footer = (attribution) => h('footer', {}, attribution ?? 'Data: National Rail', ' · ', h('a', { href: '/privacy' }, 'Privacy'));

function link(path, label, cls) {
  return h('a', { href: path, class: cls, onclick: (e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    go(path);
  } }, label);
}

// ---- navigation -------------------------------------------------------------------------------
function go(path, replace = false) {
  if (replace) history.replaceState(null, '', path); else history.pushState(null, '', path);
  route();
}

function stopTimers() {
  clearInterval(refreshTimer);
  clearInterval(clockTimer);
  refreshTimer = clockTimer = null;
}

function route() {
  gen++;
  abort.abort();
  abort = new AbortController();
  stopTimers();
  window.scrollTo(0, 0);
  const r = parseRoute(location.pathname);
  if (r.page === 'station') {
    if (location.pathname !== r.canonical) return go(r.canonical, true);
    return openStation(r.crs);
  }
  s = null;
  if (r.page === 'home') return renderHome();
  renderNotFound('Page not found');
}

// ---- search box ---------------------------------------------------------------------------------
function searchBox(placeholder) {
  const input = h('input', { type: 'search', placeholder, 'aria-label': placeholder, autocomplete: 'off',
    autocapitalize: 'off', spellcheck: 'false', role: 'combobox', 'aria-expanded': 'false', 'aria-controls': 'suggest' });
  const list = h('ul', { class: 'suggest', id: 'suggest', role: 'listbox', hidden: true });
  let results = [];
  let active = -1;
  const pick = (st) => { searchActive = null; input.blur(); go(`/station/${st.crs}`); };
  const move = (i) => { active = i; searchActive = results[i]?.crs ?? null; draw(); };
  const draw = () => {
    list.replaceChildren(...results.map((st, i) => h('li', {
      role: 'option', 'aria-selected': i === active ? 'true' : 'false',
      onmousedown: (e) => { e.preventDefault(); pick(st); },
    }, h('span', {}, st.name), h('span', { class: 'crs' }, st.crs))));
    list.hidden = results.length === 0;
    input.setAttribute('aria-expanded', String(!list.hidden));
  };
  input.addEventListener('focus', () => loadStations());
  input.addEventListener('input', async () => {
    const q = input.value;
    const all = stations ?? (await loadStations()) ?? [];
    if (q !== input.value) return; // typed on meanwhile
    results = searchStations(all, q);
    const kept = results.findIndex((x) => x.crs === searchActive); // same choice after a re-render
    active = kept >= 0 ? kept : results.length ? 0 : -1;
    draw();
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' && results.length) { move((active + 1) % results.length); e.preventDefault(); }
    else if (e.key === 'ArrowUp' && results.length) { move((active - 1 + results.length) % results.length); e.preventDefault(); }
    else if (e.key === 'Enter' && active >= 0) { e.preventDefault(); pick(results[active]); }
    else if (e.key === 'Escape') { results = []; searchActive = null; draw(); }
  });
  input.addEventListener('blur', () => setTimeout(() => { results = []; draw(); }, 150));
  return h('div', { class: 'search' }, input, list);
}

// ---- home -------------------------------------------------------------------------------------
function setMeta(title, description) {
  document.title = title;
  document.querySelector('meta[name="description"]')?.setAttribute('content', description);
}

function renderHome() {
  setMeta('What Platform — which platform is my train?',
    'Live departures, platforms and delays for every station in Great Britain.');
  const note = h('p', { class: 'note', hidden: true, role: 'status' });
  const locate = h('button', { class: 'btn', type: 'button' }, 'Use my location');
  locate.addEventListener('click', () => useLocation(locate, note));
  const recents = loadRecents(storage);
  put(
    h('div', { class: 'top' }, h('span', { class: 'logo' }, 'What Platform')),
    badge(),
    h('h1', {}, 'Which platform is my train?'),
    h('p', { class: 'tag' }, 'Live departures, platforms and delays for every station in Great Britain.'),
    locate, note,
    searchBox('Search for a station'),
    recents.length ? [h('div', { class: 'label' }, 'Recent'),
      h('div', { class: 'chips' }, recents.map((r) => link(`/station/${r.crs}`, r.name, 'chip')))] : null,
    h('div', { class: 'label' }, 'Popular stations'),
    h('div', { class: 'grid' }, POPULAR.map(([crs, name]) =>
      link(`/station/${crs}`, [name, h('span', { class: 'crs' }, crs)]))),
    footer(),
  );
}

function useLocation(button, note) {
  const say = (t) => { note.textContent = t; note.hidden = false; };
  if (!navigator.geolocation) return say('Location is off. Search for your station instead.');
  button.disabled = true;
  button.textContent = 'Finding your station…';
  const myGen = gen;
  const done = () => { button.disabled = false; button.textContent = 'Use my location'; };
  navigator.geolocation.getCurrentPosition(async (pos) => {
    const all = stations ?? (await loadStations());
    if (myGen !== gen) return;
    done();
    if (!all?.length) return say("Couldn't load the station list. Try again.");
    const { station, meters } = nearestStation(all, pos.coords.latitude, pos.coords.longitude);
    located = { crs: station.crs, meters };
    go(`/station/${station.crs}`);
  }, () => {
    if (myGen !== gen) return;
    done();
    say('Location is off. Search for your station instead.');
  }, { timeout: 10_000, maximumAge: 60_000 });
}

function renderNotFound(title) {
  setMeta(`${title} | What Platform`, 'Live departures, platforms and delays for every station in Great Britain.');
  put(
    h('div', { class: 'top' }, link('/', '← What Platform', 'logo'), badge(true)),
    h('div', { class: 'station' }, title),
    searchBox('Search for a station'),
    footer(),
  );
}

// ---- station page -----------------------------------------------------------------------------
function openStation(crs) {
  s = freshStation(crs);
  const name = nameOf(crs);
  if (name) addRecent(storage, { crs, name });
  renderStation();
  refresh();
  loadStations().then((all) => {
    if (!s || s.crs !== crs) return;
    if (all && !all.some((x) => x.crs === crs)) { s.unknown = true; renderStation(); }
    else if (all && !name) addRecent(storage, { crs, name: nameOf(crs) });
  });
  refreshTimer = setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, REFRESH_MS);
  clockTimer = setInterval(() => { if (document.visibilityState === 'visible') renderStation(); }, CLOCK_MS);
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible' || !s) return;
  renderStation(); // at once: countdowns, «Live» and stale banners from the current clock
  const age = s.board ? Date.now() - Date.parse(s.board.generatedAt) : Infinity;
  if (age > REFRESH_MS) refresh();
});

const rateLimited = () => s && Date.now() < s.rateLimitedUntil;

let inFlight = null; // {gen, promise}: one board request at a time per page

function refresh(manual = false) {
  if (!s || (rateLimited() && !manual)) return null;
  if (inFlight?.gen === gen) return inFlight.promise;
  const promise = doRefresh().finally(() => { if (inFlight?.promise === promise) inFlight = null; });
  inFlight = { gen, promise };
  return promise;
}

async function doRefresh() {
  const myGen = gen, crs = s.crs;
  try {
    const b = await fetchJson(`${API}/departures/${crs}`, fetch, abort.signal);
    if (myGen !== gen) return;
    if (!validBoard(b)) throw new ApiError('unavailable');
    s.board = b;
    s.failed = null;
  } catch (e) {
    if (myGen !== gen || e?.name === 'AbortError') return;
    s.failed = e instanceof ApiError ? e.kind : 'unavailable';
    if (s.failed === 'ratelimited') s.rateLimitedUntil = Date.now() + RATE_LIMIT_MS;
  }
  s.loading = false;
  s.pages = freshPages(s.pages, Date.now(), EXPIRE_MS);
  if (s.openSid) loadStops(s.openSid);
  if (s.board?.name) addRecent(storage, { crs, name: s.board.name });
  renderStation();
}

function livePages(now) {
  const pages = freshPages(s.pages, now, EXPIRE_MS);
  return s.board && pages.length ? contiguousPages(s.board, pages, now) : [];
}

function services(now) {
  return s.board ? mergeServices(s.board, livePages(now), now) : [];
}

function nextPageOffset(now) {
  const b = s.board;
  if (!b) return null;
  const live = livePages(now);
  const last = live.length ? live[live.length - 1] : b;
  const all = services(now);
  return nextOffset({
    prevStart: startIn(last, now),
    prevEnd: last.complete ? endIn(last, now) : null,
    lastMinutes: all.length ? londonMinutesUntil(all[all.length - 1].std, now) : null,
  });
}

const expired = (now) => s.board && now - Date.parse(s.board.generatedAt) > EXPIRE_MS;
const hasMore = (now) => !expired(now) && now >= s.stalledUntil && nextPageOffset(now) != null;
const reachedEnd = (now) => {
  const live = livePages(now);
  return live.length > 0 && live[live.length - 1].complete && !hasMore(now);
};

async function loadMore() {
  if (!s) return;
  const now = Date.now();
  const off = nextPageOffset(now);
  if (off == null || s.loadingMore || rateLimited()) return;
  const myGen = gen, crs = s.crs;
  s.loadingMore = true;
  renderStation();
  try {
    const p = await fetchJson(`${API}/departures/${crs}/${off}`, fetch, abort.signal);
    if (myGen !== gen) return;
    if (!validBoard(p)) throw new ApiError('unavailable');
    s.moreFailed = false;
    const t = Date.now();
    const live = livePages(t);
    if (coveredEnd(s.board, [...live, p], t) > coveredEnd(s.board, live, t)) {
      s.pages = [...live, p];
      s.stalledUntil = 0;
    } else {
      s.stalledUntil = t + OFFSET_STEP * 60_000;
    }
  } catch (e) {
    if (myGen !== gen || e?.name === 'AbortError') return;
    if (e instanceof ApiError && e.kind === 'ratelimited') s.rateLimitedUntil = Date.now() + RATE_LIMIT_MS;
    else s.moreFailed = true;
  }
  s.loadingMore = false;
  renderStation();
}

function toggleStops(sid) {
  s.openSid = s.openSid === sid ? null : sid;
  renderStation();
  if (s.openSid) loadStops(sid);
}

/** Fetches `sid`'s stops when missing, failed or older than the board refresh; the old ones
 * stay on screen meanwhile. Also called on every board refresh for the open train. */
async function loadStops(sid) {
  if (!sid || !stopsNeedFetch(s.stops.get(sid), Date.now())) return;
  const myGen = gen;
  const old = s.stops.get(sid);
  s.stops.set(sid, old?.state === 'ok' ? { ...old, pending: true } : { state: 'loading', at: Date.now(), pending: true });
  try {
    const j = await fetchJson(`${API}/service/${encodeURIComponent(sid)}`, fetch, abort.signal);
    if (myGen !== gen) return;
    s.stops.set(sid, { state: 'ok', portions: Array.isArray(j.portions) ? j.portions : [], at: Date.now() });
  } catch (e) {
    if (myGen !== gen || e?.name === 'AbortError') return;
    s.stops.set(sid, old?.state === 'ok' ? { ...old, at: 0 } : { state: 'error', at: Date.now() });
  }
  if (s.openSid === sid) renderStation();
}

function stopStatus(st) {
  if (st.cancelled) return h('span', { class: 'x' }, 'Cancelled');
  if (st.et && /^\d{2}:\d{2}$/.test(st.et)) return h('span', { class: 'e' }, `Exp ${st.et}`);
  if (st.et === 'Delayed') return h('span', { class: 'e' }, 'Delayed');
  return null;
}

function stopsPanel(d) {
  const sid = d.serviceId;
  const got = sid ? s.stops.get(sid) : { state: 'error' };
  let body;
  if (!got || got.state === 'loading') body = h('div', { class: 'sub' }, 'Loading stops…');
  else if (got.state === 'error') body = h('div', { class: 'sub' }, 'Stops unavailable');
  else {
    const portions = got.portions.filter((p) => Array.isArray(p))
      .map((p) => p.filter((st) => st && typeof st.st === 'string' && typeof st.name === 'string'))
      .filter((p) => p.length);
    body = portions.length === 0 ? h('div', { class: 'sub' }, 'No more stops')
      : portions.map((p) => [
        portions.length > 1 ? h('div', { class: 'to' }, `To ${p[p.length - 1].name}`) : null,
        p.map((st) => h('div', { class: 's' }, h('b', {}, st.st), h('span', {}, st.name), stopStatus(st))),
      ]);
  }
  return h('div', { class: 'stops' }, body,
    h('a', { class: 'cta', href: APP_STORE, rel: 'noopener' }, '🔔 Get alerts if your platform changes — download the app'));
}

function statusEl(d) {
  const t = statusText(d);
  if (!t) return null;
  const cls = isCancelled(d) ? 'st-bad' : isLate(d) ? 'st-late' : 'st-good';
  return h('span', { class: cls }, t);
}

function platEl(d, card) {
  if (card) {
    return d.platform != null ? h('div', { class: 'plat' }, h('small', {}, 'Platform'), d.platform)
      : h('div', { class: 'plat none' }, h('small', {}, 'Platform'), '–');
  }
  return h('div', { class: d.platform != null ? 'p' : 'p none' }, d.platform ?? '–');
}

function reasonEl(d) {
  const r = isCancelled(d) ? d.cancelReason : d.delayReason;
  return r ? h('div', { class: 'reason' }, r) : null;
}

function trainCard(d, now) {
  const cancelled = isCancelled(d);
  const mins = minutesUntilDeparture(d, now);
  const headline = cancelled ? 'Cancelled' : mins == null ? 'Delayed' : waitText(mins);
  const waitCls = cancelled ? 'wait bad' : isLate(d) ? 'wait late' : 'wait';
  const status = statusEl(d);
  return h('div', { class: 'card', role: 'button', tabindex: 0, 'data-key': `t:${trainKey(d)}`, 'aria-expanded': String(s.openSid === d.serviceId),
    onclick: () => toggleStops(d.serviceId), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleStops(d.serviceId); } } },
  h('div', { class: 'head' },
    h('div', {}, h('div', { class: 'dest' }, d.destination),
      d.via ? h('div', { class: 'sub' }, d.via) : null,
      d.operator ? h('div', { class: 'sub' }, d.operator) : null),
    platEl(d, true)),
  h('div', { class: waitCls }, headline),
  h('div', { class: 'times' }, d.std, status && statusText(d) !== headline ? [' · ', status] : null),
  reasonEl(d));
}

function trainRow(d) {
  return h('div', { class: isCancelled(d) ? 'row cancelled' : 'row', role: 'button', tabindex: 0, 'data-key': `t:${trainKey(d)}`,
    'aria-expanded': String(s.openSid === d.serviceId),
    onclick: () => toggleStops(d.serviceId), onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleStops(d.serviceId); } } },
  h('div', { class: 't' }, h('span', {}, d.std), h('small', {}, statusEl(d))),
  h('div', { class: 'd' }, h('div', { class: 'name' }, d.destination),
    d.via ? h('div', { class: 'sub' }, d.via) : null,
    d.operator ? h('div', { class: 'sub' }, d.operator) : null, reasonEl(d)),
  platEl(d, false));
}

function banner(text, onRetry) {
  return h('div', { class: 'banner', role: 'status' }, h('span', {}, text),
    onRetry ? h('button', { type: 'button', 'data-key': 'retry', onclick: onRetry }, 'Retry') : null);
}

function moreEl(now, all) {
  if (s.loadingMore) return h('div', { class: 'spinner' });
  if (hasMore(now)) {
    return h('div', { class: 'more' },
      s.moreFailed ? h('p', { role: 'status' }, "Couldn't load more trains.") : null,
      h('button', { type: 'button', 'data-key': 'more', disabled: rateLimited(), onclick: loadMore },
        s.moreFailed ? 'Try again' : 'Show more'));
  }
  if (all.length === 0) return null;
  return h('div', { class: 'more' }, h('p', {},
    reachedEnd(now) ? 'No more departures in the next 4 hours' : "That's as far ahead as we can show"));
}

function renderStation() {
  if (!s) return;
  try {
    drawStation();
  } catch (e) {
    // Never a frozen page: an answer the page cannot draw shows as the API being unavailable.
    console.error(e);
    put(h('div', { class: 'top' }, link('/', '← What Platform', 'logo'), badge(true)),
      banner("Couldn't show departures", () => { s.board = null; s.pages = []; s.loading = true; drawStation(); refresh(true); }),
      footer());
  }
}

function drawStation() {
  const now = Date.now();
  const b = s.board;
  const name = b?.name ?? nameOf(s.crs);
  if (s.unknown && !b) return renderNotFound('Station not found');
  setMeta(name ? `${name} (${s.crs}) — live departures and platforms | What Platform` : `${s.crs} | What Platform`,
    name ? `Live departures, platforms and delays at ${name}.` : 'Live departures and platforms.');

  const head = [
    h('div', { class: 'top' }, link('/', '← What Platform', 'logo'), badge(true)),
    h('div', { class: 'station' }, name ?? s.crs),
  ];
  const meta = [];
  if (located?.crs === s.crs) meta.push(h('span', {}, formatDistance(located.meters)));
  const age = b ? now - Date.parse(b.generatedAt) : 0;
  const stale = b && (s.failed || rateLimited() || age > STALE_MS);
  if (b && !stale && !expired(now)) meta.push(h('span', { class: 'live' }, `Live · ${londonHhmm(Date.parse(b.generatedAt))}`));
  head.push(h('div', { class: 'meta' }, meta), searchBox('Change station'));

  const body = [];
  if (!b) {
    if (s.loading) body.push(h('div', { class: 'spinner', 'aria-label': 'Loading' }));
    else if (s.failed === 'notfound') body.push(banner('Departures unavailable for this station', () => refresh(true)));
    else if (s.failed === 'ratelimited') body.push(banner('Busy right now. Trying again in a few minutes.'));
    else body.push(banner("Couldn't load departures", () => refresh(true)));
    put(head, body, footer());
    return;
  }
  const updated = `Last updated ${londonHhmm(Date.parse(b.generatedAt)).slice(0, 5)}`;
  if (rateLimited()) body.push(banner('Busy right now. Trying again in a few minutes.'));
  if (expired(now)) body.push(banner(updated, rateLimited() ? null : () => refresh(true)));
  else if (stale && !rateLimited()) body.push(banner(updated, () => refresh(true)));

  const all = services(now);
  const msgs = b.nrccMessages ?? [];
  if (msgs.length) {
    const open = s.alertsOpen || all.length === 0;
    body.push(h('div', { class: 'alerts' },
      h('button', { type: 'button', 'data-key': 'alerts', 'aria-expanded': String(open), onclick: () => { s.alertsOpen = !open; renderStation(); } },
        `⚠ ${msgs.length === 1 ? '1 service alert' : `${msgs.length} service alerts`}`),
      open ? msgs.map((m) => h('p', {}, m)) : null));
  }
  if (!expired(now)) {
    const dests = [];
    for (const d of all) if (!dests.includes(d.destination)) dests.push(d.destination);
    for (const f of s.filters) if (!dests.includes(f)) dests.push(f);
    if (dests.length > 1 || s.filters.size) {
      body.push(h('div', { class: 'chips' },
        h('button', { class: 'chip', type: 'button', 'data-key': 'all', 'aria-pressed': String(s.filters.size === 0),
          onclick: () => { s.filters.clear(); renderStation(); } }, 'All'),
        dests.map((d) => h('button', { class: 'chip', type: 'button', 'data-key': `c:${d}`, 'aria-pressed': String(s.filters.has(d)),
          onclick: () => { if (s.filters.has(d)) s.filters.delete(d); else s.filters.add(d); renderStation(); } }, d))));
    }
    const visible = s.filters.size ? all.filter((d) => s.filters.has(d.destination)) : all;
    const next = nextTrainIndex(visible);
    if (all.length === 0) body.push(h('div', { class: 'empty' }, 'No departures in the next 2 hours'));
    else if (visible.length === 0) body.push(h('div', { class: 'empty' }, 'No trains to these destinations right now'));
    else {
      if (next != null) {
        body.push(trainCard(visible[next], now));
        if (s.openSid && s.openSid === visible[next].serviceId) body.push(stopsPanel(visible[next]));
      }
      visible.forEach((d, i) => {
        if (i === next) return;
        body.push(trainRow(d));
        if (s.openSid && s.openSid === d.serviceId) body.push(stopsPanel(d));
      });
    }
    body.push(moreEl(now, all));
  }
  put(head, body, footer(b.attribution));
}

window.addEventListener('popstate', route);
route();

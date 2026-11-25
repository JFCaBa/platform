// Departure texts and times, as the app's app/lib/domain/departure_text.dart and the London
// clock helpers of pages.dart. Times are epoch milliseconds; clocks are London's.

const HHMM = /^\d{2}:\d{2}$/;
const MIN = 60000;

const fmt = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Europe/London', hourCycle: 'h23',
  year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
});

/** London wall clock of `ms`: {y, mo, d, h, mi, s}. */
function london(ms) {
  const p = {};
  for (const { type, value } of fmt.formatToParts(new Date(ms))) p[type] = Number(value);
  return { y: p.year, mo: p.month, d: p.day, h: p.hour, mi: p.minute, s: p.second };
}

/** Minutes London is ahead of UTC at `ms`. */
function londonOffset(ms) {
  const t = london(ms);
  return Math.round((Date.UTC(t.y, t.mo - 1, t.d, t.h, t.mi, t.s) - Math.floor(ms / 1000) * 1000) / MIN);
}

/** The instant London shows y-mo-d h:mi (an ambiguous time in October: the later one). */
function londonInstant(y, mo, d, h, mi) {
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const first = guess - londonOffset(guess) * MIN;
  return guess - londonOffset(first) * MIN;
}

/** "10:05:31" in London. */
export function londonHhmm(ms) {
  const t = london(ms);
  return [t.h, t.mi, t.s].map((v) => String(v).padStart(2, '0')).join(':');
}

export const isCancelled = (d) => d.cancelled === true || d.etd === 'Cancelled';

/** "Cancelled" | "On time" | "Exp 10:22" | "Delayed" | "" (no estimate). */
export function statusText(d) {
  if (isCancelled(d)) return 'Cancelled';
  const etd = d.etd;
  if (etd == null) return '';
  if (HHMM.test(etd)) return `Exp ${etd}`;
  return etd;
}

export const platformText = (d) => (d.platform == null ? null : `Plat ${d.platform}`);

/** Running late: an expected time other than the scheduled one, or "Delayed". */
export const isLate = (d) =>
  !isCancelled(d) && (d.etd === 'Delayed' || (d.etd != null && HHMM.test(d.etd) && d.etd !== d.std));

/** The first train that will run (the large card); null if all are cancelled. */
export function nextTrainIndex(ds) {
  const i = ds.findIndex((d) => !isCancelled(d));
  return i < 0 ? null : i;
}

/** The expected (else scheduled) London time as an instant, on the London date nearest `nowMs`. */
function departureAt(d, nowMs) {
  const etd = d.etd;
  if (etd === 'Delayed') return null;
  const t = etd != null && HHMM.test(etd) ? etd : d.std;
  if (!HHMM.test(t)) return null;
  const h = Number(t.slice(0, 2)), m = Number(t.slice(3));
  const today = london(nowMs);
  let best = null;
  for (const day of [-1, 0, 1]) {
    const at = londonInstant(today.y, today.mo, today.d + day, h, m);
    if (best == null || Math.abs(at - nowMs) < Math.abs(best - nowMs)) best = at;
  }
  return best;
}

/** Minutes from `nowMs` to the departure, floored; null when unknown. */
export function minutesUntilDeparture(d, nowMs) {
  const at = departureAt(d, nowMs);
  return at == null ? null : Math.floor(Math.trunc((at - nowMs) / 1000) / 60);
}

/** "Due", "1 min", "12 min", "1 h 05". */
export function waitText(minutes) {
  if (minutes <= 0) return 'Due';
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, '0')}`;
}

/** Minutes from `nowMs` to `hhmm` on London clocks, in [-720, 720); null for garbage. */
export function londonMinutesUntil(hhmm, nowMs) {
  const parts = String(hhmm).split(':');
  if (parts.length !== 2 || !/^\d+$/.test(parts[0]) || !/^\d+$/.test(parts[1])) return null;
  const now = london(nowMs);
  const diff = Number(parts[0]) * 60 + Number(parts[1]) - (now.h * 60 + now.mi);
  return ((((diff + 720) % 1440) + 1440) % 1440) - 720;
}

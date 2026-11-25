// "Show more": later pages of a board, a line-for-line port of app/lib/domain/pages.dart.
// Boards are the API's JSON; times are epoch milliseconds.
import { londonMinutesUntil } from './text.js';

/** Darwin's largest timeOffset: the last page reaches about 4 h ahead. */
export const MAX_OFFSET = 119;
/** Pages are asked at multiples of this, so a station's users share nginx cache entries. */
export const OFFSET_STEP = 15;
/** Furthest Darwin lists, in minutes from now: offset 119 plus its 120-min window. */
const MAX_REACH = MAX_OFFSET + 120;

/** Minutes Darwin lists from `offset`: offsets 1..118 stop at now + 120. */
export const darwinWindow = (offset) => (offset > 0 && offset < 119 ? 120 - offset : 120);

const generated = (b) => Date.parse(b.generatedAt);
const windowOf = (b) => b.window ?? darwinWindow(b.timeOffset ?? 0);

/** One train across boards: Darwin's serviceId, else scheduled time and destination. */
export const trainKey = (d) => d.serviceId ?? `${d.std}|${d.destination}`;

/** Minutes from now to where `b` starts: Darwin's offset counts from when the board was made. */
export const startIn = (b, nowMs) => (b.timeOffset ?? 0) - Math.trunc((nowMs - generated(b)) / 60000);

/** Minutes from now to the end of what `b` lists: its window when complete, else its last train. */
export function endIn(b, nowMs) {
  if (b.complete) return startIn(b, nowMs) + windowOf(b);
  let last = null;
  for (const d of b.services) {
    const m = londonMinutesUntil(d.std, nowMs);
    if (m != null && (last == null || m > last)) last = m;
  }
  return last;
}

/** Base board plus later pages as one list, by scheduled time (see pages.dart). */
export function mergeServices(base, pages, nowMs) {
  if (pages.length === 0) return base.services;
  const at = (d) => londonMinutesUntil(d.std, nowMs) ?? 0;
  const baseEnd = endIn(base, nowMs) ?? startIn(base, nowMs);
  const best = new Map();
  const order = [];
  const add = (d, gen) => {
    const k = trainKey(d);
    const seen = best.get(k);
    if (seen == null) order.push(k);
    if (seen == null || gen > seen.gen) best.set(k, { d, gen });
  };
  for (const d of base.services) add(d, generated(base));
  const baseKeys = new Set(base.services.map(trainKey));
  for (const p of pages) {
    for (const d of p.services) {
      if (baseKeys.has(trainKey(d)) || at(d) >= baseEnd) add(d, generated(p));
    }
  }
  const idx = new Map(order.map((k, i) => [k, i]));
  return order.map((k) => best.get(k).d)
    .sort((a, b) => at(a) - at(b) || idx.get(trainKey(a)) - idx.get(trainKey(b)));
}

function chain(base, pages, nowMs) {
  let covered = endIn(base, nowMs) ?? startIn(base, nowMs);
  const out = [];
  for (const p of pages) {
    if (startIn(p, nowMs) > covered) break;
    const end = endIn(p, nowMs);
    if (end == null || end <= covered) continue;
    covered = end;
    out.push(p);
  }
  return { pages: out, covered };
}

/** Pages made less than `maxAgeMs` ago. A page lists trains a few hours ahead: one left from
 * hours ago (a tab open overnight) would bring back trains that have gone. */
export const freshPages = (pages, nowMs, maxAgeMs) => pages.filter((p) => nowMs - generated(p) < maxAgeMs);

/** The pages that still follow on from `base` without a gap, in order. */
export const contiguousPages = (base, pages, nowMs) => chain(base, pages, nowMs).pages;

/** Minutes from now to the end of what `base` and its contiguous pages list. */
export const coveredEnd = (base, pages, nowMs) => chain(base, pages, nowMs).covered;

const cap = (v) => (v > MAX_OFFSET ? MAX_OFFSET : v < 1 ? 1 : v);

/** Offset of the next page, or null when Darwin cannot reach further (see pages.dart). */
export function nextOffset({ prevStart, prevEnd, lastMinutes }) {
  if (prevStart >= MAX_OFFSET) return null;
  const m = lastMinutes;
  if (prevEnd == null && m == null) return cap(prevStart + OFFSET_STEP);
  if (prevEnd != null) {
    const end = prevEnd;
    if (end < MAX_OFFSET) {
      const q = cap(Math.floor(end / OFFSET_STEP) * OFFSET_STEP);
      return q > prevStart ? q : cap(end);
    }
    return MAX_REACH - end >= OFFSET_STEP ? MAX_OFFSET : null;
  }
  const q = cap(Math.floor(m / OFFSET_STEP) * OFFSET_STEP);
  if (q > prevStart) return q;
  const exact = cap(m);
  return exact > prevStart ? exact : null;
}

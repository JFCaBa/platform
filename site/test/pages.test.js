import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeServices, contiguousPages, darwinWindow, nextOffset, startIn, endIn } from '../js/pages.js';

const now = Date.parse('2026-11-16T10:00:00Z'); // GMT
const min = 60000;
const dep = (std, { id = null, dest = 'Cambridge', etd = null } = {}) =>
  ({ std, destination: dest, cancelled: false, serviceId: id, etd });
const board = (services, { at = now, offset = 0, complete = false } = {}) =>
  ({ crs: 'KGX', generatedAt: new Date(at).toISOString(), nrccMessages: [], services, timeOffset: offset, complete });
const ids = (ds) => ds.map((d) => d.serviceId);

test('mergeServices: no pages, the base as is', () => {
  const b = board([dep('10:05', { id: 'a' })]);
  assert.equal(mergeServices(b, [], now), b.services);
});
test('mergeServices: union by time, duplicates once, same-minute trains kept', () => {
  const base = board([dep('10:05', { id: 'a' }), dep('10:40', { id: 'b' })]);
  const page = board([dep('10:40', { id: 'b' }), dep('10:40', { id: 'c' }), dep('11:10', { id: 'd' })], { offset: 30 });
  assert.deepEqual(ids(mergeServices(base, [page], now)), ['a', 'b', 'c', 'd']);
});
test('mergeServices: the most recently generated copy wins', () => {
  const base = board([dep('10:40', { id: 'b', etd: '10:52' })], { at: now + 3 * min });
  const page = board([dep('10:40', { id: 'b', etd: 'On time' })], { offset: 30 });
  assert.equal(mergeServices(base, [page], now)[0].etd, '10:52');
  const older = board([dep('10:40', { id: 'b', etd: 'On time' })], { at: now - min });
  const merged = mergeServices(older, [page], now);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].etd, 'On time');
});
test('mergeServices: page trains before the base first train have left', () => {
  const base = board([dep('10:20', { id: 'b' })]);
  const page = board([dep('10:10', { id: 'a' }), dep('10:30', { id: 'c' })], { offset: 15 });
  assert.deepEqual(ids(mergeServices(base, [page], now)), ['b', 'c']);
});
test('mergeServices: within the base window the base is the truth', () => {
  const base = board([dep('10:00', { id: 'late', etd: '10:08' }), dep('10:41', { id: 'b' })]);
  const page = board([dep('10:30', { id: 'gone' }), dep('10:41', { id: 'b2' }), dep('10:50', { id: 'c' })],
    { offset: 15, at: now - 20 * min });
  assert.deepEqual(ids(mergeServices(base, [page], now)), ['late', 'b', 'b2', 'c']);
});
test('mergeServices: dedupe without serviceId by std and destination', () => {
  const base = board([dep('10:40')]);
  const page = board([dep('10:40'), dep('10:40', { dest: 'Leeds' })], { offset: 30 });
  assert.deepEqual(mergeServices(base, [page], now).map((d) => d.destination), ['Cambridge', 'Leeds']);
});
test('mergeServices: sorted across midnight', () => {
  const late = Date.parse('2026-11-16T23:00:00Z');
  const base = board([dep('23:30', { id: 'a' })], { at: late });
  const page = board([dep('00:10', { id: 'c' }), dep('23:55', { id: 'b' })], { at: late, offset: 30 });
  assert.deepEqual(ids(mergeServices(base, [page], late)), ['a', 'b', 'c']);
});

test('contiguousPages: pages that follow on are kept', () => {
  const base = board([dep('10:05', { id: 'a' }), dep('10:41', { id: 'b' })]);
  const p1 = board([dep('10:41', { id: 'b' }), dep('11:20', { id: 'c' })], { offset: 30 });
  const p2 = board([dep('11:20', { id: 'c' })], { offset: 75, complete: true });
  assert.deepEqual(contiguousPages(base, [p1, p2], now), [p1, p2]);
});
test('contiguousPages: a page past what is listed is dropped, with the ones after it', () => {
  const base = board([dep('10:05', { id: 'a' }), dep('10:41', { id: 'b' })]);
  const old = board([dep('11:10', { id: 'c' })], { offset: 119, at: now - 60 * min });
  const later = board([dep('12:00', { id: 'd' })], { offset: 119 });
  assert.deepEqual(contiguousPages(base, [old, later], now), []);
});
test('contiguousPages: a complete base covers its whole window', () => {
  const base = board([dep('10:05', { id: 'a' })], { complete: true });
  const p = board([dep('12:30', { id: 'z' })], { offset: 119, complete: true });
  assert.deepEqual(contiguousPages(base, [p], now), [p]);
});

test('darwinWindow', () => {
  assert.deepEqual([0, 1, 45, 90, 118, 119].map(darwinWindow), [120, 119, 75, 30, 2, 120]);
});

const n = (prevStart, prevEnd, lastMinutes) => nextOffset({ prevStart, prevEnd, lastMinutes });
test('nextOffset', () => {
  assert.equal(n(0, null, 41), 30); // busy station
  assert.equal(n(0, 120, 100), 119);
  assert.equal(n(90, 120, 117), 119);
  assert.equal(n(90, 119, 117), 119);
  assert.equal(n(88, 118, 116), 105); // aged complete page filled first
  assert.equal(n(-10, 80, 79), 75);
  assert.equal(n(105, 118, 117), 118);
  assert.equal(n(119, null, null), null);
  assert.equal(n(90, null, 140), 119); // capped
  assert.equal(n(30, null, 41), 41); // saturated page
  assert.equal(n(41, null, 41), null); // could not move forward
  assert.equal(n(119, null, 200), null);
  assert.equal(n(119, 239, 200), null);
  assert.equal(n(110, 230, 200), null);
  assert.equal(n(99, 219, 200), 119);
  assert.equal(n(-5, null, 0), 1); // never below 1
  assert.equal(n(0, null, null), 15); // rows full of buses
});
test('a page made 40 min ago counts from now', () => {
  const page = board([], { offset: 30, complete: true, at: now - 40 * min });
  assert.equal(startIn(page, now), -10);
  assert.equal(endIn(page, now), 80);
});
test('the API window wins over darwinWindow', () => {
  const page = { ...board([], { offset: 30, complete: true }), window: 60 };
  assert.equal(endIn(page, now), 90);
});

import { freshPages } from '../js/pages.js';
test('freshPages drops pages older than the limit (a tab left open overnight)', () => {
  const yesterday = board([dep('18:00', { id: 'y' })], { offset: 90, at: now - 15.5 * 60 * min });
  const recent = board([dep('11:10', { id: 'r' })], { offset: 60, at: now - 2 * min });
  assert.deepEqual(freshPages([yesterday, recent], now, 10 * min), [recent]);
  const base = board([dep('10:10', { id: 'a' })]);
  assert.deepEqual(mergeServices(base, freshPages([yesterday], now, 10 * min), now).map((d) => d.serviceId), ['a']);
});

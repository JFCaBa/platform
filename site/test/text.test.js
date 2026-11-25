import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCancelled, statusText, platformText, isLate, nextTrainIndex, minutesUntilDeparture, waitText,
  londonMinutesUntil, londonHhmm } from '../js/text.js';

const dep = (std, o = {}) => ({ std, etd: 'On time', destination: 'Cambridge', cancelled: false, ...o });
const at = (iso) => Date.parse(iso);

test('isLate: an expected time or Delayed, never a cancelled train', () => {
  assert.equal(isLate(dep('10:15', { etd: 'On time' })), false);
  assert.equal(isLate(dep('10:15', { etd: '10:15' })), false);
  assert.equal(isLate(dep('10:15', { etd: '10:19' })), true);
  assert.equal(isLate(dep('10:15', { etd: 'Delayed' })), true);
  assert.equal(isLate(dep('10:15', { etd: 'Cancelled', cancelled: true })), false);
});

test('statusText, isCancelled and platformText', () => {
  assert.equal(statusText(dep('10:15', { etd: 'Cancelled' })), 'Cancelled');
  assert.equal(isCancelled(dep('10:15', { etd: 'Cancelled' })), true);
  assert.equal(statusText(dep('10:15', { cancelled: true })), 'Cancelled');
  assert.equal(statusText(dep('10:15', { etd: null })), '');
  assert.equal(statusText(dep('10:15', { etd: '10:22' })), 'Exp 10:22');
  assert.equal(statusText(dep('10:15', { etd: 'On time' })), 'On time');
  assert.equal(statusText(dep('10:15', { etd: 'Delayed' })), 'Delayed');
  assert.equal(platformText(dep('10:15', { platform: '4' })), 'Plat 4');
  assert.equal(platformText(dep('10:15', { platform: null })), null);
  assert.equal(platformText(dep('10:15')), null);
});

test('nextTrainIndex skips cancelled trains', () => {
  assert.equal(nextTrainIndex([dep('10:15', { etd: 'Cancelled', cancelled: true }), dep('10:20')]), 1);
  assert.equal(nextTrainIndex([dep('10:15', { etd: 'Cancelled', cancelled: true })]), null);
  assert.equal(nextTrainIndex([]), null);
});

test('minutesUntilDeparture uses London time, the expected time and the nearest day', () => {
  const now = at('2026-07-01T09:14:00Z'); // 10:14 BST
  assert.equal(minutesUntilDeparture(dep('10:20'), now), 6);
  assert.equal(minutesUntilDeparture(dep('10:20', { etd: '10:31' }), now), 17);
  assert.equal(minutesUntilDeparture(dep('10:20', { etd: 'Delayed' }), now), null);
  assert.equal(minutesUntilDeparture(dep('10:20', { etd: null }), now), 6);
  assert.equal(minutesUntilDeparture(dep('10:13'), now), -1);
  assert.equal(minutesUntilDeparture(dep('00:05'), at('2026-12-01T23:58:00Z')), 7);
  assert.equal(minutesUntilDeparture(dep('23:50'), at('2026-12-02T00:02:00Z')), -12);
  assert.equal(minutesUntilDeparture(dep('02:10'), at('2026-03-29T00:50:00Z')), 20); // clocks forward
  assert.equal(minutesUntilDeparture(dep('01:10'), at('2026-10-25T00:50:00Z')), 20); // clocks back
  assert.equal(minutesUntilDeparture(dep('23:58'), at('2026-11-26T00:03:00Z')), -5);
  assert.equal(minutesUntilDeparture(dep('00:05'), at('2026-11-25T23:50:00Z')), 15);
});

test('waitText', () => {
  assert.equal(waitText(0), 'Due');
  assert.equal(waitText(-2), 'Due');
  assert.equal(waitText(1), '1 min');
  assert.equal(waitText(59), '59 min');
  assert.equal(waitText(65), '1 h 05');
});

test('londonMinutesUntil (pages.dart minutesUntil)', () => {
  const now = at('2026-11-16T10:00:00Z');
  assert.equal(londonMinutesUntil('10:45', now), 45);
  assert.equal(londonMinutesUntil('09:58', now), -2);
  assert.equal(londonMinutesUntil('00:05', at('2026-11-16T23:50:00Z')), 15);
  assert.equal(londonMinutesUntil('23:50', at('2026-11-17T00:10:00Z')), -20);
  assert.equal(londonMinutesUntil('11:30', at('2026-07-01T10:00:00Z')), 30);
  assert.equal(londonMinutesUntil('soon', now), null);
});

test('londonHhmm', () => {
  assert.equal(londonHhmm(at('2026-07-01T09:05:31Z')), '10:05:31');
  assert.equal(londonHhmm(at('2026-12-01T23:58:00Z')), '23:58:00');
});

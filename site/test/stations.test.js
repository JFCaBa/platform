import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nearestStation, searchStations, formatDistance } from '../js/stations.js';

test('nearestStation picks the closest station', () => {
  const stations = [
    { crs: 'KGX', name: 'London Kings Cross', lat: 51.53088, lon: -0.12293 },
    { crs: 'STP', name: 'London St Pancras International', lat: 51.53197, lon: -0.12693 },
    { crs: 'CLJ', name: 'Clapham Junction', lat: 51.46419, lon: -0.17026 },
  ];
  const { station, meters } = nearestStation(stations, 51.5302, -0.1240);
  assert.equal(station.crs, 'KGX');
  assert.ok(meters < 200);
});

const S = [{ crs: 'KGX', name: 'London Kings Cross' }, { crs: 'STP', name: 'London St Pancras International' },
  { crs: 'KGL', name: "King's Langley" }, { crs: 'EUS', name: 'London Euston' }, { crs: 'AAP', name: 'Alexandra Palace' }];
const crs = (q, l) => searchStations(S, q, l).map((s) => s.crs);

test('search: CRS exact first, words, apostrophes, empty, limit', () => {
  assert.equal(crs('kgx')[0], 'KGX');
  assert.deepEqual(crs('st pancras'), ['STP']);
  assert.deepEqual(crs('kings').slice(0, 2).sort(), ['KGL', 'KGX']);
  assert.equal(crs('eus')[0], 'EUS');
  assert.deepEqual(crs(''), []);
  assert.deepEqual(crs('   '), []);
  assert.equal(crs('lon', 2).length, 2);
  assert.equal(crs('King’s')[0], 'KGL');
  assert.deepEqual(crs('zzzz'), []);
});

test('search: accents and case', () => {
  const A = [{ crs: 'XYZ', name: 'Llanfair Pwll' }, { crs: 'ABC', name: 'Café Junction' }];
  assert.deepEqual(searchStations(A, 'CAFE').map((s) => s.crs), ['ABC']);
});

test('formatDistance', () => {
  assert.equal(formatDistance(123), '120 m');
  assert.equal(formatDistance(1234), '1.2 km');
  assert.equal(formatDistance(123456), '123 km');
});

test('search aliases: x for cross, saint for st, intl', () => {
  const T = [{ crs: 'KGX', name: 'London Kings Cross' }, { crs: 'SAC', name: 'St Albans City' },
    { crs: 'STP', name: 'London St Pancras International' }, { crs: 'CHX', name: 'London Charing Cross' }];
  const c = (q) => searchStations(T, q).map((s) => s.crs);
  assert.equal(c('kings x')[0], 'KGX');
  assert.equal(c('charing x')[0], 'CHX');
  assert.equal(c('saint albans')[0], 'SAC');
  assert.equal(c('st pancras intl')[0], 'STP');
});

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/stations.dart';

Map<String, dynamic> fixture() => jsonDecode(File('test/fixtures/stations.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses the fixture and skips malformed entries', () {
    final idx = StationIndex.fromJson(fixture());
    expect(idx.stations.map((s) => s.crs), ['BHM', 'CLJ', 'EDB', 'KGX', 'STP', 'YSM']);
    final kgx = idx.byCrs('KGX')!;
    expect(kgx.name, 'London Kings Cross');
    expect(kgx.lat, closeTo(51.53088, 1e-6));
    expect(idx.byCrs('XXA'), isNull); // no coordinates
    expect(idx.byCrs('XXB'), isNull); // lat 200
    expect(idx.byCrs('ZZZ'), isNull);
  });

  test('accepts a newer version with extra fields', () {
    final idx = StationIndex.fromJson({
      'version': 2,
      'extra': true,
      'stations': [
        {'crs': 'KGX', 'name': 'London Kings Cross', 'lat': 51.53, 'lon': -0.12, 'zone': 1},
      ],
    });
    expect(idx.byCrs('KGX'), isNotNull);
  });

  test('rejects version 0 and indexes with no valid station', () {
    expect(() => StationIndex.fromJson({'version': 0, 'stations': fixture()['stations']}), throwsFormatException);
    expect(() => StationIndex.fromJson({'version': 1, 'stations': []}), throwsFormatException);
    expect(
        () => StationIndex.fromJson({
              'version': 1,
              'stations': [
                {'crs': 'XXA', 'name': 'x'},
                {'crs': 'XXB', 'name': 'y', 'lat': double.nan, 'lon': 0},
              ],
            }),
        throwsFormatException);
    expect(() => StationIndex.fromJson({'version': 1}), throwsFormatException);
  });

  test('search by name ignores case, accents and punctuation', () {
    final idx = StationIndex.fromJson(fixture());
    expect(idx.search('kings cross').map((s) => s.crs), ['KGX']);
    expect(idx.search("King's Cross").map((s) => s.crs), ['KGX']);
    expect(idx.search('LONDON').map((s) => s.crs), containsAll(['KGX', 'STP']));
    expect(idx.search('Ýstrad').map((s) => s.crs), ['YSM']);
    expect(idx.search('  '), isEmpty);
  });

  test('search by exact CRS comes first', () {
    final idx = StationIndex.fromJson(fixture());
    expect(idx.search('KGX').first.crs, 'KGX');
    expect(idx.search('clj').first.crs, 'CLJ');
  });

  test('search returns at most 50 results', () {
    final many = [
      for (var i = 0; i < 80; i++) {'crs': 'A${String.fromCharCode(65 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}', 'name': 'Halt $i', 'lat': 52.0, 'lon': -1.0},
    ];
    final idx = StationIndex.fromJson({'version': 1, 'stations': many});
    expect(idx.search('halt').length, 50);
  });

  test('bundled asset loads with no network', () async {
    final idx = await loadBundledStations(rootBundle);
    expect(idx.stations.length, greaterThan(2400));
    expect(idx.byCrs('KGX')!.name, 'London Kings Cross');
  });
}

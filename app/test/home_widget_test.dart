import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/data/stations.dart';
import 'package:platform_app/widget/home_widget.dart';

const kgx = Station(crs: 'KGX', name: 'London Kings Cross', lat: 51.53, lon: -0.12);

Departure dep(String std, {String? etd = 'On time', String dest = 'Cambridge', bool cancelled = false}) =>
    Departure(std: std, etd: etd, platform: '9', destination: dest, cancelled: cancelled, operator: 'GN', via: 'via X');

Board board(List<Departure> s) => Board(
      crs: 'KGX',
      name: 'London Kings Cross',
      generatedAt: DateTime.utc(2026, 11, 22, 14, 0, 30),
      nrccMessages: const [],
      attribution: 'Data: National Rail',
      services: s,
    );

void main() {
  test('snapshot carries station, sorted filters and the services the widget draws', () {
    final s = [dep('14:05'), dep('14:10', etd: '14:14', dest: 'Leeds', cancelled: true)];
    final snap = widgetSnapshot(kgx, {'Leeds', 'Cambridge'}, board(s), s);
    expect(snap['crs'], 'KGX');
    expect(snap['name'], 'London Kings Cross');
    expect(snap['filters'], ['Cambridge', 'Leeds']);
    final b = snap['board'] as Map;
    expect(b['generatedAt'], DateTime.utc(2026, 11, 22, 14, 0, 30).millisecondsSinceEpoch ~/ 1000);
    expect(b['services'], [
      {'std': '14:05', 'etd': 'On time', 'platform': '9', 'destination': 'Cambridge', 'cancelled': false},
      {'std': '14:10', 'etd': '14:14', 'platform': '9', 'destination': 'Leeds', 'cancelled': true},
    ]);
  });

  test('at most 40 services; no board yet is null so the widget fetches the new station', () {
    final s = [for (var i = 0; i < 50; i++) dep('14:${(i % 60).toString().padLeft(2, '0')}')];
    expect(((widgetSnapshot(kgx, {}, board(s), s)['board'] as Map)['services'] as List).length, 40);
    final empty = widgetSnapshot(kgx, {}, null, const []);
    expect(empty['board'], isNull);
    expect(empty['name'], 'London Kings Cross');
  });

  test('writes only on change, and again after a failed write', () async {
    final writes = <String>[];
    var fail = false;
    final p = WidgetPublisher(write: (j) async {
      if (fail) throw Exception('no');
      writes.add(j);
    });
    final s = [dep('14:05')];
    await p.publish(null, {}, board(s), s); // no station yet
    expect(writes, isEmpty);
    await p.publish(kgx, {}, board(s), s);
    await p.publish(kgx, {}, board(s), s);
    expect(writes.length, 1);
    await p.publish(kgx, {'Cambridge'}, board(s), s);
    expect(writes.length, 2);
    expect(jsonDecode(writes.last)['filters'], ['Cambridge']);
    fail = true;
    await p.publish(kgx, {}, board(s), s);
    fail = false;
    await p.publish(kgx, {}, board(s), s);
    expect(writes.length, 3);
  });
}

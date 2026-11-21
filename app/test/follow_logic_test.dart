import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/domain/position.dart';
import 'package:platform_app/follow/follow_logic.dart';
import 'package:timezone/data/latest.dart' as tzdata;

Departure dep({String std = '08:12', String dest = 'Cardiff Central', String? etd, String? platform,
        bool cancelled = false, String? cancelReason, String? id}) =>
    Departure(std: std, etd: etd, platform: platform, destination: dest, cancelled: cancelled, cancelReason: cancelReason,
        serviceId: id);

Board board(String crs, List<Departure> services) => Board(
    crs: crs, generatedAt: DateTime.utc(2026, 11, 17, 8), nrccMessages: const [], attribution: 'x', services: services);

void main() {
  setUpAll(tzdata.initializeTimeZones);
  const t = FollowedTrain(crs: 'CDF', std: '08:12', destination: 'Cardiff Central');

  test('matches ignores etd and platform', () {
    expect(t.matches(dep(etd: '08:19', platform: '5')), isTrue);
    expect(t.matches(dep(std: '08:13')), isFalse);
    expect(t.matches(dep(dest: 'Swansea')), isFalse);
  });

  test('with a serviceId, two trains at the same time to the same place are told apart', () {
    const byId = FollowedTrain(crs: 'CDF', std: '08:12', destination: 'Cardiff Central', serviceId: 'A1');
    expect(byId.matches(dep(id: 'A1')), isTrue);
    expect(byId.matches(dep(id: 'B2')), isFalse);
    expect(byId.matches(dep()), isTrue); // the board lost ids: fall back to time and destination
    expect(findFollowed(board('CDF', [dep(id: 'B2', platform: '1'), dep(id: 'A1', platform: '2')]), byId)?.platform, '2');
    expect(FollowedTrain.fromJson(byId.toJson()), byId);
    expect(FollowedTrain.fromJson(t.toJson()).serviceId, isNull);
  });

  test('findFollowed only on its station', () {
    final services = [dep(std: '08:00'), dep(platform: '3')];
    expect(findFollowed(board('CDF', services), t)?.platform, '3');
    expect(findFollowed(board('NWP', services), t), isNull);
    expect(findFollowed(board('CDF', [dep(std: '08:00')]), t), isNull);
  });

  test('ongoingTitle and ongoingText', () {
    final now = DateTime.utc(2026, 11, 17, 7, 50);
    expect(ongoingTitle(t, dep(platform: '3', etd: 'On time')), '08:12 to Cardiff Central · Plat 3');
    expect(ongoingTitle(t, dep()), '08:12 to Cardiff Central');
    expect(ongoingText(dep(platform: '3', etd: 'On time'), now, const PassedStop('Newport', '07:41', 2)),
        '22 min · On time · 2 stops away (left Newport)');
    expect(ongoingText(dep(etd: '08:20'), now, const PassedStop('Newport', '07:41', 1)),
        '30 min · Exp 08:20 · Next stop: here (left Newport)');
    expect(ongoingText(dep(), now, null), '22 min');
    expect(ongoingText(dep(etd: 'Delayed'), now, const StartsHere()), 'Delayed · Starts here');
    expect(ongoingText(dep(etd: 'Cancelled', cancelled: true), now, const StartsHere()), 'Cancelled');
    expect(t.title, '08:12 to Cardiff Central');
  });

  test('changes', () {
    expect(changes(dep(), dep(platform: '5')), ['Platform 5']);
    expect(changes(dep(platform: '3'), dep(platform: '5')), ['Platform changed: 3 → 5']);
    expect(changes(dep(platform: '3'), dep()), isEmpty);
    expect(changes(dep(etd: 'On time'), dep(etd: '08:19')), ['Now expected 08:19']);
    expect(changes(dep(etd: '08:19'), dep(etd: '08:19')), isEmpty);
    expect(changes(dep(etd: '08:19'), dep(etd: 'On time')), ['Now on time']);
    expect(changes(dep(etd: 'On time'), dep(etd: 'Delayed')), ['Delayed']);
    expect(changes(dep(), dep(etd: 'On time')), isEmpty); // first estimate, nothing changed
    expect(changes(dep(platform: '3', etd: 'On time'), dep(platform: '5', etd: '08:19')),
        ['Platform changed: 3 → 5', 'Now expected 08:19']);
    expect(changes(dep(platform: '3'), dep(platform: '5', cancelled: true, cancelReason: 'a signalling problem')),
        ['Cancelled: a signalling problem']);
    expect(changes(dep(), dep(etd: 'Cancelled')), ['Cancelled']);
    expect(changes(dep(cancelled: true), dep(cancelled: true, platform: '4')), isEmpty);
  });

  test('changes match the shared fixture', () {
    final cases = jsonDecode(File('../api/tests/fixtures/follow_changes.json').readAsStringSync()) as List;
    expect(cases, isNotEmpty);
    Departure from(Map<String, dynamic> j) => dep(
        etd: j['etd'] as String?,
        platform: j['platform'] as String?,
        cancelled: j['cancelled'] as bool? ?? false,
        cancelReason: j['cancelReason'] as String?);
    for (final c in cases) {
      expect(changes(from(c['before']), from(c['after'])), (c['alerts'] as List).cast<String>(), reason: '$c');
    }
  });

  test('FollowedTrain json round-trip', () {
    expect(FollowedTrain.fromJson(t.toJson()), t);
    expect(t == const FollowedTrain(crs: 'NWP', std: '08:12', destination: 'Cardiff Central'), isFalse);
  });
}

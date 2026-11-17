import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/follow/follow_logic.dart';

Departure dep({String std = '08:12', String dest = 'Cardiff Central', String? etd, String? platform,
        bool cancelled = false, String? cancelReason}) =>
    Departure(std: std, etd: etd, platform: platform, destination: dest, cancelled: cancelled, cancelReason: cancelReason);

Board board(String crs, List<Departure> services) => Board(
    crs: crs, generatedAt: DateTime.utc(2026, 11, 17, 8), nrccMessages: const [], attribution: 'x', services: services);

void main() {
  const t = FollowedTrain(crs: 'CDF', std: '08:12', destination: 'Cardiff Central');

  test('matches ignores etd and platform', () {
    expect(t.matches(dep(etd: '08:19', platform: '5')), isTrue);
    expect(t.matches(dep(std: '08:13')), isFalse);
    expect(t.matches(dep(dest: 'Swansea')), isFalse);
  });

  test('findFollowed only on its station', () {
    final services = [dep(std: '08:00'), dep(platform: '3')];
    expect(findFollowed(board('CDF', services), t)?.platform, '3');
    expect(findFollowed(board('NWP', services), t), isNull);
    expect(findFollowed(board('CDF', [dep(std: '08:00')]), t), isNull);
  });

  test('ongoingText', () {
    expect(ongoingText(t, dep(platform: '3', etd: 'On time')), '08:12 to Cardiff Central · Plat 3 · On time');
    expect(ongoingText(t, dep()), '08:12 to Cardiff Central');
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

  test('FollowedTrain json round-trip', () {
    expect(FollowedTrain.fromJson(t.toJson()), t);
    expect(t == const FollowedTrain(crs: 'NWP', std: '08:12', destination: 'Cardiff Central'), isFalse);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/follow/follow_logic.dart';
import 'package:platform_app/follow/follow_loop.dart';

import 'follow_logic_test.dart' show board, dep;

void main() {
  const t = FollowedTrain(crs: 'CDF', std: '08:12', destination: 'Cardiff Central');
  final t0 = DateTime.utc(2026, 11, 17, 7, 50);
  late DateTime now;
  late List<Object> results; // Board, or an exception to throw
  late int fetches;
  late List<(String, String)> alerts;
  late List<String> ongoing;
  late FollowLoop loop;

  Board on({String? platform, String? etd = 'On time', bool cancelled = false}) =>
      board('CDF', [dep(std: '08:00'), dep(platform: platform, etd: etd, cancelled: cancelled)]);
  final without = board('CDF', [dep(std: '08:00')]);

  setUp(() {
    now = t0;
    results = [];
    fetches = 0;
    alerts = [];
    ongoing = [];
    loop = FollowLoop(
      train: t,
      startedAt: t0,
      clock: () => now,
      fetch: (crs) async {
        expect(crs, 'CDF');
        fetches++;
        final r = results.removeAt(0);
        if (r is Board) return r;
        throw r;
      },
      alert: (title, body) async => alerts.add((title, body)),
      ongoing: (text) async => ongoing.add(text),
    );
  });

  Future<bool> tickAfter(Duration d, Object result) {
    now = now.add(d);
    results.add(result);
    return loop.tick();
  }

  const s30 = Duration(seconds: 30);

  test('first reading updates ongoing, no alert', () async {
    expect(await tickAfter(Duration.zero, on(platform: '3')), isTrue);
    expect(ongoing, ['08:12 to Cardiff Central · Plat 3 · On time']);
    expect(alerts, isEmpty);
  });

  test('platform change alerts once', () async {
    await tickAfter(Duration.zero, on(platform: '3'));
    await tickAfter(s30, on(platform: '5'));
    await tickAfter(s30, on(platform: '5'));
    expect(alerts, [('08:12 to Cardiff Central', 'Platform changed: 3 → 5')]);
    expect(ongoing.last, '08:12 to Cardiff Central · Plat 5 · On time');
  });

  test('errors are silent and keep the last good reading', () async {
    expect(await tickAfter(Duration.zero, on(platform: '3')), isTrue);
    expect(await tickAfter(s30, const DeparturesUnavailable('x')), isTrue);
    expect(await tickAfter(s30, const DeparturesUnavailable('x')), isTrue);
    expect(await tickAfter(s30, on(platform: '5')), isTrue);
    expect(alerts.map((a) => a.$2), ['Platform changed: 3 → 5']);
  });

  test('rate limited skips fetches for 5 min', () async {
    await tickAfter(Duration.zero, const RateLimited());
    now = now.add(const Duration(minutes: 1));
    expect(await loop.tick(), isTrue);
    expect(fetches, 1);
    expect(await tickAfter(const Duration(minutes: 4), on()), isTrue);
    expect(fetches, 2);
  });

  test('train gone from two good boards stops', () async {
    await tickAfter(Duration.zero, on());
    expect(await tickAfter(s30, without), isTrue);
    expect(await tickAfter(s30, on()), isTrue);
    expect(await tickAfter(s30, without), isTrue);
    expect(await tickAfter(s30, const DeparturesUnavailable('x')), isTrue);
    expect(await tickAfter(s30, without), isFalse);
  });

  test('cancelled alerts once and stops 2 min later', () async {
    await tickAfter(Duration.zero, on());
    expect(await tickAfter(s30, on(cancelled: true)), isTrue);
    expect(await tickAfter(s30, on(cancelled: true)), isTrue);
    expect(alerts.map((a) => a.$2), ['Cancelled']);
    expect(await tickAfter(const Duration(minutes: 1, seconds: 30), on(cancelled: true)), isFalse);
  });

  test('a cancellation taken back keeps following', () async {
    await tickAfter(Duration.zero, on());
    await tickAfter(s30, on(cancelled: true));
    expect(await tickAfter(s30, on()), isTrue);
    expect(await tickAfter(const Duration(minutes: 2), on()), isTrue);
    expect(alerts.map((a) => a.$2), ['Cancelled']);
  });

  test('first reading cancelled: no alert, stops after 2 min', () async {
    expect(await tickAfter(Duration.zero, on(cancelled: true)), isTrue);
    expect(alerts, isEmpty);
    expect(await tickAfter(const Duration(minutes: 2), on(cancelled: true)), isFalse);
  });

  test('stops after 3 h', () async {
    await tickAfter(Duration.zero, on());
    expect(await tickAfter(const Duration(hours: 3), on()), isFalse);
  });

  test('deadline wins over backoff', () async {
    await tickAfter(const Duration(hours: 2, minutes: 58), const RateLimited());
    now = t0.add(const Duration(hours: 3));
    expect(await loop.tick(), isFalse);
    expect(fetches, 1);
  });

  test('overlapping ticks fetch once', () async {
    final held = Completer<Board>();
    final slow = FollowLoop(
      train: t,
      startedAt: t0,
      clock: () => now,
      fetch: (_) {
        fetches++;
        return held.future;
      },
      alert: (_, _) async {},
      ongoing: (_) async {},
    );
    final first = slow.tick();
    expect(await slow.tick(), isTrue);
    held.complete(on());
    expect(await first, isTrue);
    expect(fetches, 1);
  });

  test('a failing notification does not stop following', () async {
    final bad = FollowLoop(
      train: t,
      startedAt: t0,
      clock: () => now,
      fetch: (_) async => on(),
      alert: (_, _) async => throw StateError('no channel'),
      ongoing: (_) async => throw StateError('no channel'),
    );
    expect(await bad.tick(), isTrue);
  });
}

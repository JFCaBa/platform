import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/app_controller.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/data/json_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeServer server;
  late FakeLocation location;
  late TimerLog timers;
  late DateTime clockNow;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ctrl');
    clockNow = DateTime.utc(2026, 11, 16, 10, 14);
    server = FakeServer(() => clockNow);
    location = FakeLocation();
    timers = TimerLog();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppController> make() async => AppController(
        server.client,
        dir,
        DeparturesClient(server.client),
        location,
        await SharedPreferences.getInstance(),
        clock: () => clockNow,
        periodic: timers.create,
      );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  Future<AppController> startedAt((double, double)? where) async {
    final c = await make();
    final started = c.start();
    await location.waitForRequest();
    location.answer(where);
    await started;
    await settle();
    return c;
  }

  group('station', () {
    test('nearest station chosen from location', () async {
      final c = await startedAt(nearKingsCross);
      expect(c.station!.crs, 'KGX');
      expect(c.distanceMeters, lessThan(200));
      expect(c.board!.crs, 'KGX');
      expect((await SharedPreferences.getInstance()).getString('last_station'), 'KGX');
    });

    test('works on first launch with no network (bundled stations)', () async {
      server.stationsFail = true;
      final c = await startedAt(nearKingsCross);
      expect(c.index!.stations.length, greaterThan(2400));
      expect(c.station!.crs, 'KGX');
    });

    test('last station remembered when location is unavailable', () async {
      SharedPreferences.setMockInitialValues({'last_station': 'BHM'});
      final c = await startedAt(null);
      expect(c.station!.crs, 'BHM');
      expect(c.needsStationPick, isFalse);
    });

    test('no location and no saved station asks to pick one', () async {
      final c = await startedAt(null);
      expect(c.station, isNull);
      expect(c.needsStationPick, isTrue);
    });

    test('resume during start (permission dialog) does not drop the location answer', () async {
      final c = await make();
      final started = c.start();
      await location.waitForRequest();
      final resumed = c.onForeground(); // iOS reports resumed when the permission dialog closes
      await settle();
      // A lookup started on resume may answer first with "no permission yet"; the dialog answer follows.
      final pending = [...location.pending];
      for (final p in pending.skip(1)) {
        p.complete(null);
      }
      await settle();
      pending.first.complete(nearKingsCross);
      await started;
      await resumed;
      await settle();
      expect(c.station?.crs, 'KGX');
      expect(c.needsStationPick, isFalse);
    });

    test('manual pick persists and is not overridden by location', () async {
      final c = await startedAt(nearKingsCross);
      c.chooseStation('BHM');
      await settle();
      expect(c.station!.crs, 'BHM');
      expect(c.board!.crs, 'BHM');
      expect((await SharedPreferences.getInstance()).getString('last_station'), 'BHM');
      c.onForeground();
      await settle();
      location.answer(nearKingsCross);
      await settle();
      expect(c.station!.crs, 'BHM');
    });

    test('useLocation goes back to the nearest station', () async {
      final c = await startedAt(nearKingsCross);
      c.chooseStation('BHM');
      await settle();
      location.immediate = nearKingsCross;
      await c.useLocation();
      await settle();
      expect(c.station!.crs, 'KGX');
    });
  });

  group('refresh', () {
    test('every 30 s only between onForeground and onBackground', () async {
      final c = await startedAt(nearKingsCross);
      expect(server.requested, ['KGX']);
      timers.fireActive();
      await settle();
      expect(server.requested.length, 2);
      c.onBackground();
      expect(timers.active, 0);
      timers.fireActive();
      await settle();
      expect(server.requested.length, 2);
      c.onForeground();
      await settle();
      location.answer(nearKingsCross);
      await settle();
      expect(timers.active, 1);
      expect(server.requested.length, 3); // foreground refreshes at once
    });

    test('failed refresh keeps the board and marks it stale', () async {
      final c = await startedAt(nearKingsCross);
      expect(c.stale, isFalse);
      server.apiFails = true;
      clockNow = clockNow.add(const Duration(seconds: 30));
      timers.fireActive();
      await settle();
      expect(c.board, isNotNull);
      expect(c.stale, isTrue);
      expect(c.expired, isFalse);
      expect(c.lastUpdated, DateTime.utc(2026, 11, 16, 10, 14));
    });

    test('after 10 min without fresh data the board expires', () async {
      final c = await startedAt(nearKingsCross);
      server.apiFails = true;
      clockNow = clockNow.add(const Duration(minutes: 10, seconds: 1));
      timers.fireActive();
      await settle();
      expect(c.expired, isTrue);
      server.apiFails = false;
      await c.retry();
      expect(c.expired, isFalse);
      expect(c.stale, isFalse);
    });

    test('a board generated more than 2 min ago is stale even when the request worked', () async {
      server.boards['KGX'] = boardJson('KGX', clockNow.subtract(const Duration(minutes: 3)));
      final c = await startedAt(nearKingsCross);
      expect(c.stale, isTrue);
      expect(c.expired, isFalse);
    });

    test('an answer generated 11 min ago (stale cache upstream) is expired', () async {
      server.boards['KGX'] = boardJson('KGX', clockNow.subtract(const Duration(minutes: 11)));
      final c = await startedAt(nearKingsCross);
      expect(c.board, isNotNull);
      expect(c.expired, isTrue);
    });

    test('expired is re-evaluated on each tick', () async {
      final c = await startedAt(nearKingsCross);
      server.hold('KGX'); // the tick's request never answers
      clockNow = clockNow.add(const Duration(minutes: 11));
      var notified = 0;
      c.addListener(() => notified++);
      timers.fireActive();
      await settle();
      expect(c.expired, isTrue);
      expect(notified, greaterThan(0));
      server.release('KGX');
    });

    for (final code in [429, 503]) {
      test('$code backs off for 5 min, then resumes', () async {
        final c = await startedAt(nearKingsCross);
        server.status['KGX'] = code;
        timers.fireActive();
        await settle();
        expect(c.rateLimited, isTrue);
        expect(c.board, isNotNull);
        final asked = server.requested.length;
        clockNow = clockNow.add(const Duration(minutes: 4, seconds: 59));
        timers.fireActive();
        await settle();
        await c.retry();
        expect(server.requested.length, asked);
        server.status.remove('KGX');
        clockNow = clockNow.add(const Duration(seconds: 2));
        timers.fireActive();
        await settle();
        expect(server.requested.length, asked + 1);
        expect(c.rateLimited, isFalse);
      });
    }
  });

  group('concurrency', () {
    test('a late answer for the previous station never overwrites the new one', () async {
      final c = await make();
      server.hold('KGX');
      final started = c.start();
      await location.waitForRequest();
      location.answer(nearKingsCross);
      await settle();
      expect(server.requested, ['KGX']);
      c.chooseStation('BHM');
      await settle();
      expect(c.board!.crs, 'BHM');
      server.release('KGX');
      await started;
      await settle();
      expect(c.station!.crs, 'BHM');
      expect(c.board!.crs, 'BHM');
    });

    test('overlapping retry and timer make one request', () async {
      final c = await startedAt(nearKingsCross);
      server.hold('KGX');
      final asked = server.requested.length;
      final r = c.retry();
      timers.fireActive();
      c.onForeground();
      await settle();
      expect(server.requested.length, asked + 1);
      server.release('KGX');
      await r;
    });
  });

  group('filters', () {
    test('toggle, persist per station, clear', () async {
      final c = await startedAt(nearKingsCross);
      expect(c.destinations, ['Cambridge', 'Leeds']);
      c.toggleFilter('Leeds');
      expect(c.visibleServices.map((d) => d.destination), ['Leeds']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('filters_KGX'), '["Leeds"]');
      c.clearFilters();
      expect(c.visibleServices.length, 2);
    });

    test('a saved filter with no trains right now stays selectable', () async {
      SharedPreferences.setMockInitialValues({'filters_KGX': '["York"]'});
      final c = await startedAt(nearKingsCross);
      expect(c.filters, {'York'});
      expect(c.destinations, containsAll(['Cambridge', 'Leeds', 'York']));
      expect(c.visibleServices, isEmpty);
    });
  });

  test('stations cache is refreshed in the background', () async {
    await startedAt(nearKingsCross);
    expect(await stationsCache(server.client, dir).loadCached(), isNotNull);
  });
}

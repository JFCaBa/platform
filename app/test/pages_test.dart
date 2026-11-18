import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/domain/pages.dart';
import 'package:timezone/data/latest.dart' as tzdata;

// 16 Nov 2026 is GMT: London clocks = UTC.
final now = DateTime.utc(2026, 11, 16, 10, 0);

Departure dep(String std, {String? id, String dest = 'Cambridge', String? etd}) =>
    Departure(std: std, destination: dest, cancelled: false, serviceId: id, etd: etd);

Board board(List<Departure> s, {DateTime? at, int offset = 0, bool complete = false}) => Board(
      crs: 'KGX',
      generatedAt: at ?? now,
      nrccMessages: const [],
      attribution: 'x',
      services: s,
      timeOffset: offset,
      complete: complete,
    );

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('minutesUntil', () {
    test('same day', () => expect(minutesUntil('10:45', now), 45));
    test('just left', () => expect(minutesUntil('09:58', now), -2));
    test('after midnight', () => expect(minutesUntil('00:05', DateTime.utc(2026, 11, 16, 23, 50)), 15));
    test('before midnight', () => expect(minutesUntil('23:50', DateTime.utc(2026, 11, 17, 0, 10)), -20));
    test('London summer time', () => expect(minutesUntil('11:30', DateTime.utc(2026, 7, 1, 10, 0)), 30));
    test('garbage', () => expect(minutesUntil('soon', now), isNull));
  });

  group('mergeServices', () {
    test('no pages: the base as is', () {
      final b = board([dep('10:05', id: 'a')]);
      expect(mergeServices(b, const [], now), same(b.services));
    });

    test('union by time, duplicates once, same-minute trains kept', () {
      final base = board([dep('10:05', id: 'a'), dep('10:40', id: 'b')]);
      final page = board([dep('10:40', id: 'b'), dep('10:40', id: 'c'), dep('11:10', id: 'd')], offset: 30);
      expect(mergeServices(base, [page], now).map((d) => d.serviceId), ['a', 'b', 'c', 'd']);
    });

    test('the most recently generated copy wins', () {
      final base = board([dep('10:40', id: 'b', etd: '10:52')], at: now.add(const Duration(minutes: 3)));
      final page = board([dep('10:40', id: 'b', etd: 'On time')], offset: 30);
      expect(mergeServices(base, [page], now).single.etd, '10:52');
      final older = board([dep('10:40', id: 'b', etd: 'On time')], at: now.subtract(const Duration(minutes: 1)));
      expect(mergeServices(older, [page], now).single.etd, 'On time');
    });

    test('page trains before the base first train have left and are dropped', () {
      final base = board([dep('10:20', id: 'b')]);
      final page = board([dep('10:10', id: 'a'), dep('10:30', id: 'c')], offset: 15);
      expect(mergeServices(base, [page], now).map((d) => d.serviceId), ['b', 'c']);
    });

    test('within the base window the base is the truth: a page train it no longer lists is gone', () {
      // Base made now lists a delayed 10:00 and runs to 10:41 (busy); the page made earlier
      // still has 10:30 (left) and 10:41 + 10:50 beyond.
      final base = board([dep('10:00', id: 'late', etd: '10:08'), dep('10:41', id: 'b')]);
      final page = board([dep('10:30', id: 'gone'), dep('10:41', id: 'b2'), dep('10:50', id: 'c')],
          offset: 15, at: now.subtract(const Duration(minutes: 20)));
      expect(mergeServices(base, [page], now).map((d) => d.serviceId), ['late', 'b', 'b2', 'c']);
    });

    test('dedupe without serviceId by std and destination', () {
      final base = board([dep('10:40')]);
      final page = board([dep('10:40'), dep('10:40', dest: 'Leeds')], offset: 30);
      expect(mergeServices(base, [page], now).map((d) => d.destination), ['Cambridge', 'Leeds']);
    });

    test('sorted across midnight', () {
      final late = DateTime.utc(2026, 11, 16, 23, 0);
      final base = board([dep('23:30', id: 'a')], at: late);
      final page = board([dep('00:10', id: 'c'), dep('23:55', id: 'b')], at: late, offset: 30);
      expect(mergeServices(base, [page], late).map((d) => d.serviceId), ['a', 'b', 'c']);
    });
  });

  group('contiguousPages', () {
    test('pages that follow on are kept', () {
      final base = board([dep('10:05', id: 'a'), dep('10:41', id: 'b')]);
      final p1 = board([dep('10:41', id: 'b'), dep('11:20', id: 'c')], offset: 30);
      final p2 = board([dep('11:20', id: 'c')], offset: 75, complete: true);
      expect(contiguousPages(base, [p1, p2], now), [p1, p2]);
    });

    test('a page that starts past what is listed is dropped, with the ones after it', () {
      // Busy base listing to 10:41; a page made an hour ago at offset 119 starts at 10:59.
      final base = board([dep('10:05', id: 'a'), dep('10:41', id: 'b')]);
      final old = board([dep('11:10', id: 'c')], offset: 119, at: now.subtract(const Duration(hours: 1)));
      final later = board([dep('12:00', id: 'd')], offset: 119);
      expect(contiguousPages(base, [old, later], now), isEmpty);
    });

    test('a complete base covers its whole window', () {
      final base = board([dep('10:05', id: 'a')], complete: true);
      final p = board([dep('12:30', id: 'z')], offset: 119, complete: true);
      expect(contiguousPages(base, [p], now), [p]);
    });
  });

  group('darwinWindow', () {
    test('offsets 1..118 stop at now + 120; 0 and 119 get 120', () {
      expect([0, 1, 45, 90, 118, 119].map(darwinWindow), [120, 119, 75, 30, 2, 120]);
    });
  });

  group('nextOffset', () {
    test('busy station: floor of the last train to 15', () {
      expect(nextOffset(prevStart: 0, prevEnd: null, lastMinutes: 41), 30);
    });
    test('a complete board jumps to 119, the only offset past now + 120', () {
      expect(nextOffset(prevStart: 0, prevEnd: 120, lastMinutes: 100), 119);
      expect(nextOffset(prevStart: 90, prevEnd: 120, lastMinutes: 117), 119); // real CLJ, 18-11
      expect(nextOffset(prevStart: 90, prevEnd: 119, lastMinutes: 117), 119);
    });
    test('an aged complete page that ends short of +119 is filled first (no gap)', () {
      expect(nextOffset(prevStart: 88, prevEnd: 118, lastMinutes: 116), 105); // offset 90, 2 min old
      expect(nextOffset(prevStart: -10, prevEnd: 80, lastMinutes: 79), 75); // offset 30, 40 min old
      expect(nextOffset(prevStart: 105, prevEnd: 118, lastMinutes: 117), 118); // floor would not move
    });
    test('a 119 page with no trains does not ask 119 again', () {
      expect(nextOffset(prevStart: 119, prevEnd: null, lastMinutes: null), isNull);
    });
    test('capped at 119', () {
      expect(nextOffset(prevStart: 90, prevEnd: null, lastMinutes: 140), 119);
    });
    test('saturated page (< 15 min): exact minute, no gap', () {
      expect(nextOffset(prevStart: 30, prevEnd: null, lastMinutes: 41), 41);
    });
    test('stops when the last page could not move forward', () {
      expect(nextOffset(prevStart: 41, prevEnd: null, lastMinutes: 41), isNull);
    });
    test('nothing after 119', () {
      expect(nextOffset(prevStart: 119, prevEnd: null, lastMinutes: 200), isNull);
      expect(nextOffset(prevStart: 119, prevEnd: 239, lastMinutes: 200), isNull);
    });
    test('an aged complete 119 page asks again only when that adds 15 min', () {
      expect(nextOffset(prevStart: 110, prevEnd: 230, lastMinutes: 200), isNull);
      expect(nextOffset(prevStart: 99, prevEnd: 219, lastMinutes: 200), 119);
    });
    test('a page made 40 min ago counts from now', () {
      // Complete offset-30 page made at 09:20: Darwin listed 09:50–11:20 (window 90) = 80 min from 10:00.
      final page = board(const [], offset: 30, complete: true, at: now.subtract(const Duration(minutes: 40)));
      expect(startIn(page, now), -10);
      expect(endIn(page, now), 80);
      expect(nextOffset(prevStart: -10, prevEnd: 80, lastMinutes: 79), 75);
    });
    test('never below 1', () {
      expect(nextOffset(prevStart: -5, prevEnd: null, lastMinutes: 0), 1);
    });
    test('empty list', () {
      expect(nextOffset(prevStart: 0, prevEnd: null, lastMinutes: null), 15); // rows full of buses
    });
  });
}

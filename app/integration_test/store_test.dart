// Drives the real app through the store screens with a fixed clock and a chosen board, so
// screenshots and the preview video are the same every time. Not part of `flutter test`.
//
//   flutter test integration_test/store_test.dart -d <simulator>
//
// It prints "SCENE <name>" and holds each screen for [hold] so a host script can capture it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/app_controller.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/follow/follow_logic.dart';
import 'package:platform_app/follow/follower.dart';
import 'package:platform_app/location.dart';
import 'package:platform_app/main.dart';
import 'package:platform_app/ui/departure_row.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

const hold = Duration(seconds: 4);

/// Friday morning rush at London King's Cross (GMT in November: London = UTC).
DateTime clock() => DateTime.utc(2026, 11, 20, 8, 12, 5);

class _Location implements LocationSource {
  @override
  Future<(double, double)?> current({bool requestPermission = false}) async => (51.5309, -0.1233);
}

/// Following without notifications: just remembers the train.
class _Follower extends ChangeNotifier implements Follower {
  @override
  FollowedTrain? current;
  @override
  Future<bool> follow(FollowedTrain t) async {
    current = t;
    notifyListeners();
    return true;
  }

  @override
  Future<void> stop() async {
    current = null;
    notifyListeners();
  }

  @override
  Future<void> sync() async {}
  @override
  Future<void> openSettings() async {}
}

Map<String, Object?> svc(String std, String dest, String op,
        {String etd = 'On time', String? plat, String? via, bool cancelled = false, String? reason}) =>
    {
      'std': std,
      'etd': cancelled ? 'Cancelled' : etd,
      'platform': plat,
      'destination': dest,
      'via': via,
      'operator': op,
      'cancelled': cancelled,
      'delayReason': cancelled ? null : reason,
      'cancelReason': cancelled ? reason : null,
      'serviceId': 'S$std${dest.substring(0, 3)}',
    };

const gn = 'Great Northern', lner = 'London North Eastern Railway';

final boards = {
  'KGX': [
    svc('08:16', 'Cambridge', gn, plat: '9'),
    svc('08:18', 'Peterborough', gn, etd: '08:24', plat: '11', reason: 'This train has been delayed by a signalling fault'),
    svc('08:21', 'Edinburgh', lner, plat: '4', via: 'via York'),
    svc('08:24', 'Leeds', lner, cancelled: true, reason: 'This train has been cancelled because of a fault on this train'),
    svc('08:30', 'Royston', gn, plat: '10'),
    svc('08:33', "King's Lynn", gn, plat: '9'),
    svc('08:40', 'Newcastle', lner, etd: '08:42'),
    svc('08:44', 'Hertford North', gn),
    svc('08:48', 'Ely', gn),
    svc('09:00', 'Edinburgh', lner),
  ],
};

List<Map<String, Object?>> stops(List<(String, String, String?)> s) =>
    [for (final (name, st, et) in s) {'name': name, 'st': st, 'et': et ?? 'On time', 'cancelled': false}];

final services = {
  'S08:16Cam': stops([
    ('Finsbury Park', '08:21', null), ('Potters Bar', '08:31', null), ('Hatfield', '08:37', null),
    ('Welwyn North', '08:42', null), ('Stevenage', '08:49', null), ('Hitchin', '08:54', null),
    ('Letchworth Garden City', '09:00', null), ('Baldock', '09:04', null), ('Royston', '09:12', null),
    ('Cambridge', '09:31', null),
  ]),
  'S08:18Pet': stops([
    ('Finsbury Park', '08:23', '08:29'), ('Stevenage', '08:41', '08:46'), ('Hitchin', '08:47', '08:52'),
    ('Arlesey', '08:52', '08:56'), ('Biggleswade', '08:58', '09:02'), ('Sandy', '09:02', '09:05'),
    ('St Neots', '09:09', '09:12'), ('Huntingdon', '09:17', '09:19'), ('Peterborough', '09:31', '09:32'),
  ]),
};

http.Client api() => MockClient((req) async {
      final seg = req.url.pathSegments;
      final body = switch (seg) {
        ['departures', final crs] => {
            'crs': crs,
            'name': crs,
            'generatedAt': clock().toIso8601String().replaceFirst('.000', ''),
            'nrccMessages': <String>[],
            'attribution': 'Data: National Rail',
            'services': boards[crs] ?? <Object>[],
            'complete': true,
          },
        ['service', final id] when services.containsKey(id) => {'portions': [services[id]]},
        _ => null,
      };
      if (body == null) return http.Response('not found', 404); // stations: the bundled copy
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screens', (tester) async {
    tzdata.initializeTimeZones();
    SharedPreferences.setMockInitialValues({'recent_stations': '["KGX","LDS","YRK","EDB"]'});
    final client = api();
    final departures = DeparturesClient(client);
    final c = AppController(client, Directory.systemTemp.createTempSync('store'), departures, _Location(),
        await SharedPreferences.getInstance(),
        clock: clock);

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pumpAndSettle();
    }

    Future<void> scene(String name) async {
      await tester.pump(const Duration(milliseconds: 600));
      // ignore: avoid_print
      print('SCENE $name');
      await tester.runAsync(() => Future<void>.delayed(hold));
      await tester.pump();
    }

    await tester.pumpWidget(PlatformApp(controller: c, follower: _Follower(), fetchStops: departures.fetchStops));
    await until(() => c.board?.services.isNotEmpty == true);
    await settle();
    await scene('board');

    // Delays and cancellations: the trains to Peterborough and Leeds.
    for (final d in ['Peterborough', 'Leeds']) {
      final chip = find.widgetWithText(FilterChip, d);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    await scene('delays');
    final all = find.widgetWithText(FilterChip, 'All');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pumpAndSettle();

    // The stops still ahead of the late train.
    await tester.tap(find.widgetWithText(DepartureRow, 'Peterborough'));
    await settle();
    await scene('stops');
    await tester.tap(find.widgetWithText(DepartureRow, 'Peterborough'));
    await tester.pumpAndSettle();

    // Follow the next train.
    await tester.tap(find.byType(NextTrainCard));
    await settle();
    await tester.tap(find.text('Follow this train'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await scene('follow');
    ScaffoldMessenger.of(tester.element(find.byType(NextTrainCard))).hideCurrentSnackBar();
    await tester.tap(find.byType(NextTrainCard));
    await tester.pumpAndSettle();

    // Any station.
    await tester.tap(find.text('London Kings Cross'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Edin');
    await tester.pumpAndSettle();
    await scene('search');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/app_controller.dart';
import 'package:platform_app/config.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/main.dart';
import 'package:platform_app/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support.dart';

void main() {
  late Directory dir;
  late FakeServer server;
  late FakeLocation location;
  late TimerLog timers;
  late DateTime clockNow;
  late List<Uri> opened;

  setUpAll(tzdata.initializeTimeZones);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('home');
    clockNow = DateTime.utc(2026, 7, 1, 9, 14); // BST: London is UTC+1
    server = FakeServer(() => clockNow);
    location = FakeLocation()..immediate = nearKingsCross;
    timers = TimerLog();
    opened = [];
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppController> pumpHome(WidgetTester tester) async {
    late AppController c;
    await tester.runAsync(() async {
      c = AppController(server.client, dir, DeparturesClient(server.client), location,
          await SharedPreferences.getInstance(), clock: () => clockNow, periodic: timers.create);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c, openUrl: (u) async => opened.add(u))));
    await tester.pump();
    return c;
  }

  testWidgets('header, rows, attribution and privacy link', (tester) async {
    await pumpHome(tester);
    expect(find.text('London Kings Cross'), findsOneWidget); // from stations.json, not the API name
    expect(find.textContaining(' m'), findsWidgets); // distance
    expect(find.text('Plat 9'), findsOneWidget);
    expect(find.text('Exp 10:22'), findsOneWidget);
    expect(find.text('Data: National Rail'), findsOneWidget);
    await tester.tap(find.text('Privacy'));
    expect(opened, [Uri.parse(privacyUrl)]);
  });

  testWidgets('empty board says so', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, services: []);
    await pumpHome(tester);
    expect(find.text('No departures in the next 2 hours'), findsOneWidget);
  });

  testWidgets('keeps API order', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, services: [
      service('23:58', etd: '00:03', destination: 'Peterborough'),
      service('00:10', destination: 'Cambridge'),
    ]);
    await pumpHome(tester);
    final late = tester.getTopLeft(find.text('23:58')).dy;
    final early = tester.getTopLeft(find.text('00:10')).dy;
    expect(late, lessThan(early));
    expect(find.text('Exp 00:03'), findsOneWidget);
  });

  testWidgets('NRCC messages collapsed into one line, expanded on tap', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, nrcc: ['Disruption between Hitchin and Cambridge.', 'Lifts out of order.']);
    await pumpHome(tester);
    expect(find.text('2 service alerts'), findsOneWidget);
    expect(find.text('Disruption between Hitchin and Cambridge.'), findsNothing);
    expect(find.text('Plat 9'), findsOneWidget); // trains stay on the first screen
    await tester.tap(find.text('2 service alerts'));
    await tester.pump();
    expect(find.text('Disruption between Hitchin and Cambridge.'), findsOneWidget);
    expect(find.text('Lifts out of order.'), findsOneWidget);
  });

  testWidgets('alerts start open when there are no trains (e.g. replacement buses)', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, services: [], nrcc: ['Replacement buses are running from this station.']);
    await pumpHome(tester);
    expect(find.text('Replacement buses are running from this station.'), findsOneWidget);
    expect(find.text('No departures in the next 2 hours'), findsOneWidget);
  });

  testWidgets('alerts open when a refresh leaves no trains', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, nrcc: ['Signal failure.']);
    await pumpHome(tester);
    expect(find.text('Signal failure.'), findsNothing);
    server.boards['KGX'] = boardJson('KGX', clockNow, services: [], nrcc: ['Signal failure.']);
    await tester.runAsync(() async {
      timers.fireActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.text('Signal failure.'), findsOneWidget);
  });

  testWidgets('a single NRCC message reads "1 service alert"', (tester) async {
    server.boards['KGX'] = boardJson('KGX', clockNow, nrcc: ['Lifts out of order.']);
    await pumpHome(tester);
    expect(find.text('1 service alert'), findsOneWidget);
  });

  testWidgets('stale banner in London time, then expired hides services', (tester) async {
    final c = await pumpHome(tester);
    server.apiFails = true;
    clockNow = clockNow.add(const Duration(seconds: 30));
    await tester.runAsync(() async {
      timers.fireActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.text('Last updated 10:14'), findsOneWidget); // 09:14 UTC = 10:14 BST
    expect(find.text('Plat 9'), findsOneWidget);
    clockNow = clockNow.add(const Duration(minutes: 10));
    await tester.runAsync(() async {
      timers.fireActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(c.expired, isTrue);
    expect(find.text('Plat 9'), findsNothing);
    expect(find.text('Last updated 10:14'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('rate limited banner', (tester) async {
    await pumpHome(tester);
    server.status['KGX'] = 429;
    await tester.runAsync(() async {
      timers.fireActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.textContaining('Busy right now'), findsOneWidget);
  });

  testWidgets('switching station while rate limited shows the banner, not a spinner', (tester) async {
    final c = await pumpHome(tester);
    server.status['KGX'] = 429;
    await tester.runAsync(() async {
      timers.fireActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    c.chooseStation('BHM');
    await tester.pump();
    expect(c.board, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Busy right now'), findsOneWidget);
  });

  testWidgets('filter chips', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'Leeds'));
    await tester.pump();
    expect(find.text('Plat 9'), findsNothing); // Cambridge row hidden
    expect(find.text('Plat 4'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'All'));
    await tester.pump();
    expect(find.text('Plat 9'), findsOneWidget);
  });

  testWidgets('picker search finds Birmingham and switches station', (tester) async {
    final c = await pumpHome(tester);
    await tester.tap(find.text('London Kings Cross'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'birm');
    await tester.pump();
    expect(find.text('Birmingham New Street'), findsOneWidget);
    await tester.tap(find.text('Birmingham New Street'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(c.station!.crs, 'BHM');
  });

  testWidgets('no location and no saved station', (tester) async {
    location.immediate = null;
    late AppController c;
    await tester.runAsync(() async {
      c = AppController(server.client, dir, DeparturesClient(server.client), location,
          await SharedPreferences.getInstance(), clock: () => clockNow, periodic: timers.create);
      final s = c.start();
      await location.waitForRequest();
      location.answer(null);
      await s;
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    await tester.pump();
    expect(find.text("We don't know where you are."), findsOneWidget);
    expect(find.text('Choose station'), findsOneWidget);
  });

  testWidgets('app title', (tester) async {
    late AppController c;
    await tester.runAsync(() async {
      c = AppController(server.client, dir, DeparturesClient(server.client), FakeLocation(),
          await SharedPreferences.getInstance(), clock: () => clockNow, periodic: timers.create);
    });
    await tester.pumpWidget(PlatformApp(controller: c));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'What Platform');
  });
}

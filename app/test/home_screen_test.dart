import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/app_controller.dart';
import 'package:platform_app/config.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/follow/follow_logic.dart';
import 'package:platform_app/follow/follower.dart';
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

  Future<AppController> pumpHome(WidgetTester tester, {Follower? follower, StopsFetcher? fetchStops}) async {
    late AppController c;
    await tester.runAsync(() async {
      c = AppController(server.client, dir, DeparturesClient(server.client), location,
          await SharedPreferences.getInstance(), clock: () => clockNow, periodic: timers.create);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c, openUrl: (u) async => opened.add(u), follower: follower, fetchStops: fetchStops)));
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
  group('stops and following', () {
    const cambridge = FollowedTrain(crs: 'KGX', std: '09:30', destination: 'Cambridge', serviceId: 'S30');
    final bell = find.byIcon(Icons.notifications_active);
    late List<String> asked;
    late Object stopsResult; // portions (List<List<Stop>>) or an exception
    setUp(() {
      asked = [];
      stopsResult = const [
        [
          Stop(name: 'Finsbury Park', st: '09:35', et: 'On time', cancelled: false),
          Stop(name: 'Hitchin', st: '10:05', et: '10:09', cancelled: false),
          Stop(name: 'Royston', st: '10:20', et: 'Cancelled', cancelled: true),
        ],
      ];
      server.boards['KGX'] = boardJson('KGX', clockNow, services: [
        service('09:20', destination: 'Leeds', serviceId: 'S20'),
        service('09:30', destination: 'Cambridge', platform: '10', serviceId: 'S30'),
        service('09:40', destination: 'York'),
      ]);
    });
    Future<List<List<Stop>>> stops(String id) async {
      asked.add(id);
      final r = stopsResult;
      if (r is List<List<Stop>>) return r;
      throw r;
    }

    Future<AppController> pump(WidgetTester tester, {Follower? follower}) =>
        pumpHome(tester, follower: follower, fetchStops: stops);

    Future<void> openRow(WidgetTester tester, String std) async {
      await tester.tap(find.text(std));
      await tester.pumpAndSettle();
    }

    testWidgets('tapping a row shows its stops, tapping again hides them', (tester) async {
      await pump(tester);
      await openRow(tester, '09:30');
      expect(asked, ['S30']);
      expect(find.text('Finsbury Park'), findsOneWidget);
      expect(find.text('09:35'), findsOneWidget);
      expect(find.text('Exp 10:09'), findsOneWidget);
      expect(find.text('Royston'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      await openRow(tester, '09:30');
      expect(find.text('Finsbury Park'), findsNothing);
    });

    testWidgets('a train that splits shows each portion under its destination', (tester) async {
      stopsResult = const [
        [
          Stop(name: 'Horsham', st: '10:00', cancelled: false),
          Stop(name: 'Portsmouth Harbour', st: '11:00', cancelled: false),
        ],
        [Stop(name: 'Bognor Regis', st: '10:50', cancelled: false)],
      ];
      await pump(tester);
      await openRow(tester, '09:30');
      expect(find.text('To Portsmouth Harbour'), findsOneWidget);
      expect(find.text('To Bognor Regis'), findsOneWidget);
      expect(tester.getTopLeft(find.text('To Bognor Regis')).dy,
          greaterThan(tester.getTopLeft(find.text('Portsmouth Harbour')).dy));
    });

    testWidgets('a single portion has no heading', (tester) async {
      await pump(tester);
      await openRow(tester, '09:30');
      expect(find.textContaining('To '), findsNothing);
    });

    testWidgets('one train open at a time', (tester) async {
      await pump(tester);
      await openRow(tester, '09:30');
      await openRow(tester, '09:20');
      expect(asked, ['S30', 'S20']);
      expect(find.text('Finsbury Park'), findsOneWidget); // same fake stops, shown once: only one panel
    });

    testWidgets('stops unavailable on error or without an id', (tester) async {
      stopsResult = const DeparturesUnavailable('x');
      await pump(tester);
      await openRow(tester, '09:30');
      expect(find.text('Stops unavailable'), findsOneWidget);
      await openRow(tester, '09:40');
      expect(find.text('Stops unavailable'), findsOneWidget);
      expect(asked, ['S30']);
    });

    testWidgets('follow and stop from the open row', (tester) async {
      final f = FakeFollower();
      await pump(tester, follower: f);
      await openRow(tester, '09:30');
      await tester.tap(find.text('Follow this train'));
      await tester.pump();
      expect(f.current, cambridge);
      expect(find.text('Following 09:30 to Cambridge'), findsOneWidget);
      expect(bell, findsOneWidget);
      await tester.tap(find.text('Stop following'));
      await tester.pump();
      expect(f.current, isNull);
      expect(find.text('Stopped following'), findsOneWidget);
    });

    testWidgets('long press follows and unfollows', (tester) async {
      final f = FakeFollower();
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(f.current, cambridge);
      expect(bell, findsOneWidget);
      expect((tester.getCenter(bell).dy - tester.getCenter(find.text('Plat 10')).dy).abs(), lessThan(30));
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(f.current, isNull);
    });

    testWidgets('Undo stops following', (tester) async {
      final f = FakeFollower();
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // snackbar slid in
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(f.current, isNull);
      expect(bell, findsNothing);
    });

    testWidgets('permission denied', (tester) async {
      final f = FakeFollower(granted: false);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(f.current, isNull);
      expect(find.text('Allow notifications to follow a train'), findsOneWidget);
      expect(bell, findsNothing);
    });

    testWidgets('permission denied offers Settings', (tester) async {
      final f = FakeFollower(granted: false);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // snackbar slid in
      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(f.settingsOpened, 1);
    });

    testWidgets('FollowFailure.notifications also offers Settings', (tester) async {
      final f = FakeFollower()..failure = const FollowFailed(FollowFailure.notifications);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(find.text('Allow notifications to follow a train'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('network failure has no Settings action', (tester) async {
      final f = FakeFollower()..failure = const FollowFailed(FollowFailure.network);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('gone shows "That train has left"', (tester) async {
      final f = FakeFollower()..failure = const FollowFailed(FollowFailure.gone);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(f.current, isNull);
      expect(find.text('That train has left'), findsOneWidget);
      expect(bell, findsNothing);
    });

    testWidgets('network failure says so', (tester) async {
      final f = FakeFollower()..failure = const FollowFailed(FollowFailure.network);
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(find.text("Couldn't follow: check your connection"), findsOneWidget);
    });

    testWidgets('a follow replaced meanwhile shows no "Following" snackbar', (tester) async {
      final f = FakeFollower()..adopt = false; // follow() succeeds, but another train is current by then
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(find.textContaining('Following'), findsNothing);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('Undo that fails to re-follow shows the reason', (tester) async {
      const york = FollowedTrain(crs: 'KGX', std: '09:40', destination: 'York');
      final f = FakeFollower()..current = york;
      await pump(tester, follower: f);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      f.failure = const FollowFailed(FollowFailure.gone);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the Undo snackbar slid out, the reason in
      expect(tester.takeException(), isNull);
      expect(find.text('That train has left'), findsOneWidget);
    });

    testWidgets('bell only on the followed station', (tester) async {
      final f = FakeFollower()..current = const FollowedTrain(crs: 'CBG', std: '09:30', destination: 'Cambridge');
      await pump(tester, follower: f);
      expect(bell, findsNothing);
    });

    testWidgets('no follower: stops, but no follow button and long press does nothing', (tester) async {
      await pump(tester);
      await openRow(tester, '09:30');
      expect(find.text('Finsbury Park'), findsOneWidget);
      expect(find.text('Follow this train'), findsNothing);
      await tester.longPress(find.text('09:30'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}

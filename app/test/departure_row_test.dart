import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/ui/departure_row.dart';
import 'package:timezone/data/latest.dart' as tzdata;

Departure dep(String std, {String? etd = 'On time', String? platform, bool cancelled = false, String dest = 'Cambridge',
        String? via, String? delayReason, String? cancelReason}) =>
    Departure(std: std, etd: etd, platform: platform, destination: dest, via: via, operator: 'Great Northern',
        cancelled: cancelled, delayReason: delayReason, cancelReason: cancelReason);

Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

/// The default test font (Ahem) draws every glyph as a full square, about twice as wide as
/// a real phone font: load Roboto from the Flutter SDK so widths are realistic.
Future<void> loadRoboto() async {
  final dir = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    loader.addFont(Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  setUpAll(loadRoboto);
  setUpAll(tzdata.initializeTimeZones);

  test('isLate: an expected time or Delayed, never a cancelled train', () {
    expect(isLate(dep('10:15', etd: 'On time')), isFalse);
    expect(isLate(dep('10:15', etd: '10:15')), isFalse);
    expect(isLate(dep('10:15', etd: '10:19')), isTrue);
    expect(isLate(dep('10:15', etd: 'Delayed')), isTrue);
    expect(isLate(dep('10:15', etd: 'Cancelled', cancelled: true)), isFalse);
  });

  test('nextTrainIndex skips cancelled trains', () {
    expect(nextTrainIndex([dep('10:15', etd: 'Cancelled', cancelled: true), dep('10:20')]), 1);
    expect(nextTrainIndex([dep('10:15', etd: 'Cancelled', cancelled: true)]), isNull);
    expect(nextTrainIndex([]), isNull);
  });

  test('minutesUntil uses London time, the expected time and the nearest day', () {
    final now = DateTime.utc(2026, 7, 1, 9, 14); // 10:14 BST
    expect(minutesUntil(dep('10:20'), now), 6);
    expect(minutesUntil(dep('10:20', etd: '10:31'), now), 17);
    expect(minutesUntil(dep('10:20', etd: 'Delayed'), now), isNull);
    expect(minutesUntil(dep('10:20', etd: null), now), 6);
    expect(minutesUntil(dep('10:13'), now), -1);
    final late = DateTime.utc(2026, 12, 1, 23, 58); // 23:58 GMT
    expect(minutesUntil(dep('00:05'), late), 7);
    expect(minutesUntil(dep('23:50'), DateTime.utc(2026, 12, 2, 0, 2)), -12);
    // clocks go forward 29-03-2026 at 01:00 GMT: 00:50 GMT to 02:10 BST is 20 minutes
    expect(minutesUntil(dep('02:10'), DateTime.utc(2026, 3, 29, 0, 50)), 20);
    // clocks go back 25-10-2026 at 01:00 UTC: 00:50 UTC (01:50 BST) to 01:10 GMT is 20 minutes
    expect(minutesUntil(dep('01:10'), DateTime.utc(2026, 10, 25, 0, 50)), 20);
    // an hour that happens twice (25-10-2026): the instant nearest now, BST or GMT
    expect(minutesUntil(dep('01:40'), DateTime.utc(2026, 10, 25, 0, 30)), 10); // 01:30 BST
    expect(minutesUntil(dep('01:40'), DateTime.utc(2026, 10, 25, 1, 30)), 10); // 01:30 GMT
    // a 01:10 still on the board at 01:20 BST is the GMT one, 50 min away; two minutes ago is Due
    expect(minutesUntil(dep('01:10'), DateTime.utc(2026, 10, 25, 0, 20)), 50);
    expect(minutesUntil(dep('01:10'), DateTime.utc(2026, 10, 25, 0, 12)), -2);
  });

  test('waitText', () {
    expect(waitText(0), 'Due');
    expect(waitText(-2), 'Due');
    expect(waitText(1), '1 min');
    expect(waitText(59), '59 min');
    expect(waitText(65), '1 h 05');
  });

  testWidgets('next-train card: wait, time, status and a large platform', (tester) async {
    final now = DateTime.utc(2026, 7, 1, 9, 14);
    await tester.pumpWidget(wrap(NextTrainCard(dep('10:20', etd: '10:23', platform: '10A', dest: 'Leeds'), nowUtc: now)));
    expect(find.text('9 min'), findsOneWidget);
    expect(find.text('10:20'), findsOneWidget);
    expect(find.text('Exp 10:23'), findsOneWidget);
    expect(find.text('Leeds'), findsOneWidget);
    expect(find.text('10A'), findsOneWidget);
    expect(find.text('Platform'), findsOneWidget);
  });

  testWidgets('next-train card without a platform says it is not out yet; Delayed replaces the wait', (tester) async {
    final now = DateTime.utc(2026, 7, 1, 9, 14);
    await tester.pumpWidget(wrap(NextTrainCard(dep('10:20', etd: 'Delayed'), nowUtc: now)));
    expect(find.text('Platform not yet shown'), findsOneWidget);
    expect(find.text('Delayed'), findsOneWidget);
  });

  testWidgets('cancelled row is dimmed; a late status is amber, not red', (tester) async {
    await tester.pumpWidget(wrap(Column(children: [
      DepartureRow(dep('10:15', etd: 'Cancelled', cancelled: true)),
      DepartureRow(dep('10:20', etd: '10:25')),
    ])));
    expect(find.byType(Opacity), findsOneWidget);
    final ctx = tester.element(find.text('Exp 10:25'));
    expect(tester.widget<Text>(find.text('Exp 10:25')).style?.color, lateColor(ctx));
  });

  test('statusText', () {
    expect(statusText(dep('10:15', etd: 'On time')), 'On time');
    expect(statusText(dep('10:15', etd: '10:22')), 'Exp 10:22');
    expect(statusText(dep('10:15', etd: 'Delayed')), 'Delayed');
    expect(statusText(dep('10:15', etd: 'Cancelled')), 'Cancelled');
    expect(statusText(dep('10:15', etd: null, cancelled: true)), 'Cancelled');
    expect(statusText(dep('10:15', etd: null)), '');
  });

  test('platformText', () {
    expect(platformText(dep('10:15', platform: '9')), 'Plat 9');
    expect(platformText(dep('10:15', platform: '10A')), 'Plat 10A');
    expect(platformText(dep('10:15')), isNull);
  });

  testWidgets('midnight crossover shows both strings as given', (tester) async {
    await tester.pumpWidget(wrap(DepartureRow(dep('23:58', etd: '00:03', platform: '2'))));
    expect(find.text('23:58'), findsOneWidget);
    expect(find.text('Exp 00:03'), findsOneWidget);
    expect(find.text('Plat 2'), findsOneWidget);
  });

  testWidgets('cancelled row is styled as cancelled and shows the reason', (tester) async {
    await tester.pumpWidget(wrap(DepartureRow(dep('10:15', etd: 'Cancelled', cancelled: true, cancelReason: 'Points failure'))));
    final std = tester.widget<Text>(find.text('10:15'));
    expect(std.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Points failure'), findsOneWidget);
  });

  for (final scale in [1.0, 1.35, 2.0]) {
    testWidgets('time stays on one line with text scale $scale on a narrow phone', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3; // 360 pt wide
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
        child: wrap(ListView(children: [
          DepartureRow(dep('16:23', etd: '16:41', platform: '10B', dest: 'Falmouth Docks')),
          DepartureRow(dep('17:11', platform: '1', dest: 'Bradford Forster Square via Leeds and a very long way')),
        ])),
      ));
      for (final t in ['16:23', 'Exp 16:41', '17:11']) {
        final p = tester.renderObject<RenderParagraph>(find.text(t));
        final boxes = p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: t.length));
        expect(boxes.map((b) => b.top.round()).toSet().length, 1, reason: '$t wrapped at scale $scale');
      }
      // destinations line up whatever the status text
      expect(tester.getTopLeft(find.text('Falmouth Docks')).dx,
          tester.getTopLeft(find.textContaining('Bradford')).dx);
    });
  }

  testWidgets('via and delay reason are shown', (tester) async {
    await tester.pumpWidget(wrap(DepartureRow(dep('10:15', etd: 'Delayed', via: 'via Hitchin', delayReason: 'Late crew'))));
    expect(find.text('Cambridge'), findsOneWidget);
    expect(find.text('via Hitchin'), findsOneWidget);
    expect(find.text('Late crew'), findsOneWidget);
  });
}

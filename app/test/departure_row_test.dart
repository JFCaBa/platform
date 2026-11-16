import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/ui/departure_row.dart';

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

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/ui/departure_row.dart';

Departure dep(String std, {String? etd = 'On time', String? platform, bool cancelled = false, String dest = 'Cambridge',
        String? via, String? delayReason, String? cancelReason}) =>
    Departure(std: std, etd: etd, platform: platform, destination: dest, via: via, operator: 'Great Northern',
        cancelled: cancelled, delayReason: delayReason, cancelReason: cancelReason);

Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
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

  testWidgets('via and delay reason are shown', (tester) async {
    await tester.pumpWidget(wrap(DepartureRow(dep('10:15', etd: 'Delayed', via: 'via Hitchin', delayReason: 'Late crew'))));
    expect(find.text('Cambridge'), findsOneWidget);
    expect(find.text('via Hitchin'), findsOneWidget);
    expect(find.text('Late crew'), findsOneWidget);
  });
}

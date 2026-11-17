import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:platform_app/data/stations.dart';
import 'package:platform_app/ui/station_picker.dart';

void main() {
  final index = StationIndex.fromJson(
      jsonDecode(File('test/fixtures/stations.json').readAsStringSync()) as Map<String, dynamic>);

  testWidgets('the open keyboard does not cover the last result', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => pickStation(context, index, null), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'n'); // every station; Ystrad Mynach is last
    await tester.pumpAndSettle();
    // the last result, scrolled as far as it goes, ends above the keyboard
    await tester.scrollUntilVisible(find.text('Ystrad Mynach'), 100, scrollable: find.byType(Scrollable).last);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.text('Ystrad Mynach')).dy, lessThanOrEqualTo(600 - 300));
  });
}

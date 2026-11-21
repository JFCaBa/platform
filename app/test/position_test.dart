import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/domain/position.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('TrainPosition.fromJson', () {
    test('three shapes', () {
      expect(TrainPosition.fromJson({'lastStop': 'Stevenage', 'lastAt': '16:31', 'stopsAway': 2}),
          const PassedStop('Stevenage', '16:31', 2));
      expect(TrainPosition.fromJson({'notStarted': 'London Kings Cross'}), const NotStarted('London Kings Cross'));
      expect(TrainPosition.fromJson({'startsHere': true}), const StartsHere());
    });

    test('missing or bad is null', () {
      expect(TrainPosition.fromJson(null), isNull);
      expect(TrainPosition.fromJson('x'), isNull);
      expect(TrainPosition.fromJson({'lastStop': 'A', 'stopsAway': 0}), isNull);
      expect(TrainPosition.fromJson({'lastStop': 5, 'stopsAway': 2}), isNull);
    });
  });

  test('whereText matches the server', () {
    expect(whereText(const PassedStop('Stevenage', '16:31', 2)), '2 stops away · left Stevenage 16:31');
    expect(whereText(const PassedStop('Hitchin', '16:38', 1)), 'Next stop: here · left Hitchin 16:38');
    expect(whereText(const PassedStop('Hitchin', null, 1)), 'Next stop: here · left Hitchin');
    expect(whereText(const NotStarted('London Kings Cross')), 'Not yet left London Kings Cross');
    expect(whereText(const StartsHere()), 'Starts here');
    expect(whereText(null), isNull);
  });

  group('contentState', () {
    final now = DateTime.utc(2026, 11, 21, 16, 30);
    Departure d({String? etd, String? platform, bool cancelled = false}) => Departure(
        std: '16:42', etd: etd, platform: platform, destination: 'Peterborough', cancelled: cancelled);

    test('running train', () {
      expect(contentState(d(etd: '16:48', platform: '10'), const PassedStop('Stevenage', '16:31', 2), now), {
        'departs': DateTime.utc(2026, 11, 21, 16, 48).millisecondsSinceEpoch ~/ 1000,
        'status': 'Exp 16:48',
        'platform': '10',
        'where': '2 stops away · left Stevenage 16:31',
        'cancelled': false,
      });
    });

    test('on time uses std; delayed has no departs', () {
      expect(contentState(d(etd: 'On time'), null, now)['departs'],
          DateTime.utc(2026, 11, 21, 16, 42).millisecondsSinceEpoch ~/ 1000);
      expect(contentState(d(etd: 'Delayed'), null, now)['departs'], isNull);
    });

    test('cancelled', () {
      expect(contentState(d(etd: 'Cancelled', cancelled: true), const StartsHere(), now),
          {'departs': null, 'status': 'Cancelled', 'platform': null, 'where': null, 'cancelled': true});
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/stations.dart';
import 'package:platform_app/domain/nearest.dart';

void main() {
  const stations = [
    Station(crs: 'KGX', name: 'London Kings Cross', lat: 51.53088, lon: -0.12293),
    Station(crs: 'STP', name: 'London St Pancras International', lat: 51.53197, lon: -0.12693),
    Station(crs: 'CLJ', name: 'Clapham Junction', lat: 51.46419, lon: -0.17026),
  ];

  test('picks closest station', () {
    final (station, meters) = nearestStation(stations, 51.5302, -0.1240); // King's Cross forecourt
    expect(station.crs, 'KGX');
    expect(meters, lessThan(200));
  });
}

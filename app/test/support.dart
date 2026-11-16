import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:platform_app/location.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response okJson(String body) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> service(String std,
        {String? etd = 'On time',
        String? platform,
        String destination = 'Cambridge',
        String? via,
        bool cancelled = false,
        String? delayReason,
        String? cancelReason}) =>
    {
      'std': std,
      'etd': etd,
      'platform': platform,
      'destination': destination,
      'via': via,
      'operator': 'Great Northern',
      'cancelled': cancelled,
      'delayReason': delayReason,
      'cancelReason': cancelReason,
    };

String boardJson(String crs, DateTime generatedAt,
        {List<Map<String, dynamic>>? services, List<String> nrcc = const [], String? name}) =>
    jsonEncode({
      'crs': crs,
      'name': name ?? '$crs board',
      'generatedAt': generatedAt.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+'), ''),
      'nrccMessages': nrcc,
      'attribution': 'Data: National Rail',
      'services': services ??
          [
            service('10:15', platform: '9'),
            service('10:20', etd: '10:22', destination: 'Leeds', platform: '4'),
          ],
    });

/// stations.json (fixture) on Pages and /departures/{CRS} on the API.
class FakeServer {
  FakeServer(this.now);

  /// Server time used for generatedAt when no board is set for a CRS.
  DateTime Function() now;

  final boards = <String, String>{}; // CRS -> body
  final status = <String, int>{}; // CRS -> HTTP status (default 200)
  final holds = <String, Completer<void>>{}; // CRS -> gate
  bool apiFails = false;
  bool stationsFail = false;
  final requested = <String>[]; // CRS codes asked to the API, in order

  void hold(String crs) => holds[crs] = Completer<void>();
  void release(String crs) => holds.remove(crs)?.complete();

  late final http.Client client = MockClient((req) async {
    if (req.url.host == 'jfcaba.github.io') {
      if (stationsFail) throw const SocketException('offline');
      return okJson(fixture('stations.json'));
    }
    final crs = req.url.pathSegments.last;
    requested.add(crs);
    final gate = holds[crs];
    if (gate != null) await gate.future;
    if (apiFails) throw const SocketException('offline');
    final code = status[crs] ?? 200;
    if (code != 200) return http.Response('{"error":"x"}', code);
    return okJson(boards[crs] ?? boardJson(crs, now()));
  });
}

/// Location whose answers the test releases by hand.
class FakeLocation implements LocationSource {
  final pending = <Completer<(double, double)?>>[];
  (double, double)? immediate;
  final requests = <bool>[];

  @override
  Future<(double, double)?> current({bool requestPermission = false}) {
    requests.add(requestPermission);
    if (immediate != null) return Future.value(immediate);
    final c = Completer<(double, double)?>();
    pending.add(c);
    return c.future;
  }

  void answer((double, double)? coords) {
    for (final c in pending) {
      if (!c.isCompleted) c.complete(coords);
    }
    pending.clear();
  }
}

const nearKingsCross = (51.5302, -0.1240);
const nearBirmingham = (52.4779, -1.8990);

/// Records periodic timers so tests can fire them and count the live ones.
class TimerLog {
  final timers = <FakeTimer>[];
  Timer create(Duration d, void Function(Timer) cb) => FakeTimer(cb)..register(this);
  int get active => timers.where((t) => t.isActive).length;
  void fireActive() {
    for (final t in [...timers]) {
      if (t.isActive) t.fire();
    }
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.cb);
  final void Function(Timer) cb;
  bool _active = true;
  void register(TimerLog log) => log.timers.add(this);
  void fire() => cb(this);
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

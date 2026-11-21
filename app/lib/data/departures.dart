import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../domain/position.dart';

class Departure {
  const Departure({
    required this.std,
    this.etd,
    this.platform,
    required this.destination,
    this.via,
    this.operator,
    required this.cancelled,
    this.delayReason,
    this.cancelReason,
    this.serviceId,
  });

  final String std;
  final String? etd;
  final String? platform;
  final String destination;
  final String? via;
  final String? operator;
  final bool cancelled;
  final String? delayReason;
  final String? cancelReason;

  /// Darwin's id for this train today; asks for its stops. Null from an older API.
  final String? serviceId;

  factory Departure.fromJson(Map<String, dynamic> j) => Departure(
        std: j['std'] as String,
        etd: j['etd'] as String?,
        platform: j['platform'] as String?,
        destination: j['destination'] as String,
        via: j['via'] as String?,
        operator: j['operator'] as String?,
        cancelled: j['cancelled'] as bool? ?? false,
        delayReason: j['delayReason'] as String?,
        cancelReason: j['cancelReason'] as String?,
        serviceId: j['serviceId'] as String?,
      );
}

/// A stop still ahead of a train.
class Stop {
  const Stop({required this.name, required this.st, this.et, required this.cancelled});

  final String name;

  /// Scheduled time, "15:25".
  final String st;

  /// "On time" | "15:31" | "Delayed" | "Cancelled" | null.
  final String? et;
  final bool cancelled;

  factory Stop.fromJson(Map<String, dynamic> j) => Stop(
        name: j['name'] as String,
        st: j['st'] as String,
        et: j['et'] as String?,
        cancelled: j['cancelled'] as bool? ?? false,
      );
}

class Board {
  const Board({
    required this.crs,
    this.name,
    required this.generatedAt,
    required this.nrccMessages,
    required this.attribution,
    required this.services,
    this.timeOffset = 0,
    this.complete = false,
    this._window,
  });

  final String crs;
  final String? name;

  /// When Darwin generated this board (UTC). A cached answer keeps its old time.
  final DateTime generatedAt;
  final List<String> nrccMessages;
  final String attribution;
  final List<Departure> services;

  /// Minutes ahead this board starts (0 = the base board, later pages 1..119).
  final int timeOffset;

  /// Minutes Darwin lists from [timeOffset] (see [darwinWindow]).
  int get window => _window ?? darwinWindow(timeOffset);
  final int? _window;

  /// Fewer rows than asked: the whole [window] is listed. False from an older API, which
  /// only makes the app ask for the next page sooner.
  final bool complete;

  factory Board.fromJson(Map<String, dynamic> j) => Board(
        crs: j['crs'] as String,
        name: j['name'] as String?,
        generatedAt: DateTime.parse(j['generatedAt'] as String).toUtc(),
        nrccMessages: [for (final m in j['nrccMessages'] as List? ?? const []) m as String],
        attribution: j['attribution'] as String,
        services: [for (final s in j['services'] as List) Departure.fromJson(s as Map<String, dynamic>)],
        timeOffset: j['timeOffset'] as int? ?? 0,
        complete: j['complete'] as bool? ?? false,
        window: j['window'] as int?,
      );
}

/// Minutes Darwin lists from [offset] (measured 18-11-2026): for offsets 1..118 the board stops at
/// now + 120 min whatever the window asked; offsets 0 and 119 get the full 120. The API sends it
/// as `window`; this is the fallback.
int darwinWindow(int offset) => offset > 0 && offset < 119 ? 120 - offset : 120;

/// How long to wait after a 429.
const rateLimitBackoff = Duration(minutes: 5);

/// Darwin asked us to slow down (429): back off for minutes.
class RateLimited implements Exception {
  const RateLimited();
  @override
  String toString() => 'RateLimited';
}

/// No board: network error, timeout, server error or an unreadable answer.
class DeparturesUnavailable implements Exception {
  const DeparturesUnavailable(this.cause);
  final Object cause;
  @override
  String toString() => 'DeparturesUnavailable($cause)';
}

/// A train's stops ahead (one list per portion) and where it is now (null from an older API).
class ServiceDetails {
  const ServiceDetails({required this.portions, this.position});
  final List<List<Stop>> portions;
  final TrainPosition? position;
}

class DeparturesClient {
  DeparturesClient(this._client, {this.baseUrl = apiBaseUrl, this.timeout = const Duration(seconds: 10)});

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  /// The board from [offset] minutes ahead (0 = next trains; later pages 1..119).
  Future<Board> fetch(String crs, {int offset = 0}) async {
    final path = '$baseUrl/departures/${Uri.encodeComponent(crs)}${offset == 0 ? '' : '/$offset'}';
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(path), headers: {'User-Agent': userAgent})
          .timeout(timeout);
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
    if (resp.statusCode == 429) throw const RateLimited();
    if (resp.statusCode != 200) throw DeparturesUnavailable('HTTP ${resp.statusCode}');
    try {
      return Board.fromJson(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
  }

  /// The stops still ahead of a train, one list per portion (a train that splits has several:
  /// the main one first). Optional data: every failure is [DeparturesUnavailable].
  Future<List<List<Stop>>> fetchStops(String serviceId) async => (await fetchService(serviceId)).portions;

  /// The stops still ahead and where the train is now. Every failure is [DeparturesUnavailable].
  Future<ServiceDetails> fetchService(String serviceId) async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse('$baseUrl/service/${Uri.encodeComponent(serviceId)}'), headers: {'User-Agent': userAgent})
          .timeout(timeout);
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
    if (resp.statusCode != 200) throw DeparturesUnavailable('HTTP ${resp.statusCode}');
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      return ServiceDetails(
        portions: [
          for (final p in j['portions'] as List) [for (final s in p as List) Stop.fromJson(s as Map<String, dynamic>)],
        ],
        position: TrainPosition.fromJson(j['position']),
      );
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

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
  });

  final String crs;
  final String? name;

  /// When Darwin generated this board (UTC). A cached answer keeps its old time.
  final DateTime generatedAt;
  final List<String> nrccMessages;
  final String attribution;
  final List<Departure> services;

  factory Board.fromJson(Map<String, dynamic> j) => Board(
        crs: j['crs'] as String,
        name: j['name'] as String?,
        generatedAt: DateTime.parse(j['generatedAt'] as String).toUtc(),
        nrccMessages: [for (final m in j['nrccMessages'] as List? ?? const []) m as String],
        attribution: j['attribution'] as String,
        services: [for (final s in j['services'] as List) Departure.fromJson(s as Map<String, dynamic>)],
      );
}

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

class DeparturesClient {
  DeparturesClient(this._client, {this.baseUrl = apiBaseUrl, this.timeout = const Duration(seconds: 10)});

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  Future<Board> fetch(String crs) async {
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse('$baseUrl/departures/${Uri.encodeComponent(crs)}'), headers: {'User-Agent': userAgent})
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
  Future<List<List<Stop>>> fetchStops(String serviceId) async {
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
      return [
        for (final p in j['portions'] as List) [for (final s in p as List) Stop.fromJson(s as Map<String, dynamic>)],
      ];
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
  }
}

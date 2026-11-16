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

/// The server asked us to back off (429/503).
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
    if (resp.statusCode == 429 || resp.statusCode == 503) throw const RateLimited();
    if (resp.statusCode != 200) throw DeparturesUnavailable('HTTP ${resp.statusCode}');
    try {
      return Board.fromJson(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeparturesUnavailable(e);
    }
  }
}

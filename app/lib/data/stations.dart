import 'dart:convert';

import 'package:flutter/services.dart';

class Station {
  const Station({required this.crs, required this.name, required this.lat, required this.lon});
  final String crs;
  final String name;
  final double lat;
  final double lon;
}

final _crsRe = RegExp(r'^[A-Z]{3}$');

/// All National Rail stations (stations.json from the pipeline).
class StationIndex {
  StationIndex(List<Station> stations)
      : stations = List.unmodifiable(stations),
        _byCrs = {for (final s in stations) s.crs: s},
        _keys = [for (final s in stations) _fold(s.name)];

  final List<Station> stations;
  final Map<String, Station> _byCrs;
  final List<String> _keys;

  /// Accepts any `version >= 1` and ignores unknown fields; malformed entries are skipped.
  /// Throws [FormatException] when no valid station remains.
  factory StationIndex.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || version < 1) throw FormatException('stations.json version $version');
    final raw = json['stations'];
    if (raw is! List) throw const FormatException('stations.json without stations');
    final out = <Station>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final crs = e['crs'], name = e['name'], lat = e['lat'], lon = e['lon'];
      if (crs is! String || !_crsRe.hasMatch(crs) || name is! String || name.isEmpty) continue;
      if (lat is! num || lon is! num) continue;
      final la = lat.toDouble(), lo = lon.toDouble();
      if (!la.isFinite || !lo.isFinite || la.abs() > 90 || lo.abs() > 180) continue;
      out.add(Station(crs: crs, name: name, lat: la, lon: lo));
    }
    if (out.isEmpty) throw const FormatException('stations.json has no valid station');
    return StationIndex(out);
  }

  Station? byCrs(String crs) => _byCrs[crs];

  /// Exact CRS first, then names containing the query (case, accent and punctuation
  /// insensitive), at most 50.
  List<Station> search(String query) {
    final q = _fold(query);
    if (q.isEmpty) return const [];
    final out = <Station>[];
    final exact = _byCrs[query.trim().toUpperCase()];
    if (exact != null) out.add(exact);
    for (var i = 0; i < stations.length && out.length < 50; i++) {
      if (_keys[i].contains(q) && !identical(stations[i], exact)) out.add(stations[i]);
    }
    return out;
  }
}

final _alnum = RegExp(r'[a-z0-9]');

const _accents = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ŵ': 'w', 'ŷ': 'y', 'ç': 'c', 'ñ': 'n',
};

/// Lowercase, accents removed, only letters and digits (so "King's Cross" = "kings cross").
String _fold(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final c = _accents[ch] ?? ch;
    if (_alnum.hasMatch(c)) b.write(c);
  }
  return b.toString();
}

const bundledStationsAsset = 'assets/stations.json';

/// The copy shipped in the app: used on first launch before (or without) any download.
Future<StationIndex> loadBundledStations(AssetBundle bundle) async =>
    StationIndex.fromJson(jsonDecode(await bundle.loadString(bundledStationsAsset)) as Map<String, dynamic>);

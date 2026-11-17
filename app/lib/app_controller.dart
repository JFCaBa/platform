import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'data/departures.dart';
import 'data/json_cache.dart';
import 'data/stations.dart';
import 'domain/nearest.dart';
import 'location.dart';

const _lastStationKey = 'last_station';
String _filtersKey(String crs) => 'filters_$crs';

const refreshInterval = Duration(seconds: 30);
const staleAfter = Duration(minutes: 2);
const expireAfter = Duration(minutes: 10);

typedef PeriodicTimerFactory = Timer Function(Duration, void Function(Timer));

DateTime _utcNow() => DateTime.now().toUtc();

/// Station index, location and departures; exposes what the screen shows.
class AppController extends ChangeNotifier {
  AppController(
    http.Client client,
    Directory cacheDir,
    this._departures,
    this._location,
    this._prefs, {
    DateTime Function()? clock,
    PeriodicTimerFactory? periodic,
    AssetBundle? bundle,
  })  : _clock = clock ?? _utcNow,
        _periodic = periodic ?? Timer.periodic,
        _bundle = bundle ?? rootBundle,
        _stationsCache = stationsCache(client, cacheDir);

  final DeparturesClient _departures;
  final LocationSource _location;
  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  final PeriodicTimerFactory _periodic;
  final AssetBundle _bundle;
  final JsonCache<StationIndex> _stationsCache;

  StationIndex? index;
  Station? station;
  double? distanceMeters;
  (double, double)? coords;
  bool manualStation = false;
  bool needsStationPick = false;
  String? error;

  /// Last board received for [station] (never another station's).
  Board? board;

  /// Destinations the list is filtered by; empty = all.
  Set<String> filters = {};

  /// A user-requested retry is running.
  bool retrying = false;

  bool _lastFailed = false;
  DateTime? _rateLimitedUntil;
  int _stationGen = 0;
  int _locationGen = 0;
  bool _locating = false;
  String? _inFlightCrs;
  Future<void>? _inFlight;
  bool _background = false;
  Future<void>? _starting;
  bool _started = false;
  Timer? _timer;
  bool _disposed = false;

  DateTime now() => _clock();

  /// Darwin's generation time of the board on screen.
  DateTime? get lastUpdated => board?.generatedAt;

  /// The last refresh failed, or the board is more than 2 min old.
  bool get stale {
    final t = lastUpdated;
    return t != null && (_lastFailed || rateLimited || now().difference(t) > staleAfter);
  }

  /// More than 10 min since the board was generated: too old to show trains.
  bool get expired {
    final t = lastUpdated;
    return t != null && now().difference(t) > expireAfter;
  }

  bool get rateLimited {
    final until = _rateLimitedUntil;
    return until != null && now().isBefore(until);
  }

  /// No board could be loaded for the current station.
  bool get loadFailed => board == null && _lastFailed;

  /// Destinations on the board (API order), plus selected ones with no train right now.
  List<String> get destinations {
    final out = <String>[];
    for (final d in board?.services ?? const <Departure>[]) {
      if (!out.contains(d.destination)) out.add(d.destination);
    }
    for (final f in filters) {
      if (!out.contains(f)) out.add(f);
    }
    return out;
  }

  List<Departure> get visibleServices {
    final s = board?.services ?? const <Departure>[];
    return filters.isEmpty ? s : s.where((d) => filters.contains(d.destination)).toList();
  }

  /// First load. Later calls return the same future.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _locating = true; // don't ask to pick a station before GPS has had its chance
    index = await _stationsCache.loadCached();
    if (index == null) {
      try {
        index = await loadBundledStations(_bundle);
      } catch (_) {
        // Only the network copy is left.
      }
    }
    if (_disposed) return;
    _resolveStation();
    _notify();
    _startTimer();
    await Future.wait([_refreshIndex(), _locate(requestPermission: true)]);
    await _inFlight;
    _started = true;
  }

  Future<void> onForeground() async {
    _background = false;
    if (_starting != null && !_started) {
      // start() is still running (e.g. iOS reports "resumed" when the permission dialog
      // closes): a second lookup now would drop the answer to that dialog.
      _startTimer();
      await _starting;
      return;
    }
    _startTimer();
    _notify(); // expired may have changed while away
    await Future.wait([if (!manualStation) _locate(), _refresh()]);
  }

  void onBackground() {
    _background = true;
    _locationGen++; // drop answers that arrive while in the background
    _locating = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> retry() async {
    if (retrying) return;
    retrying = true;
    _notify();
    try {
      await Future.wait([
        if (index == null) _refreshIndex(),
        if (!manualStation && station == null) _locate(requestPermission: true),
        _refresh(),
      ]);
    } finally {
      retrying = false;
      _notify();
    }
  }

  void chooseStation(String crs) {
    final s = index?.byCrs(crs);
    if (s == null) return;
    _locationGen++;
    _locating = false;
    manualStation = true;
    _setStation(s);
    _notify();
  }

  /// Leave the manual choice and go back to the nearest station.
  Future<void> useLocation() async {
    manualStation = false;
    await _locate(requestPermission: true);
  }

  void toggleFilter(String dest) {
    final next = {...filters};
    if (!next.remove(dest)) next.add(dest);
    _setFilters(next);
  }

  void clearFilters() => _setFilters({});

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setFilters(Set<String> next) {
    filters = next;
    final s = station;
    if (s != null) _prefs.setString(_filtersKey(s.crs), jsonEncode(next.toList()..sort()));
    _notify();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _background) return;
    _timer = _periodic(refreshInterval, (_) {
      _notify(); // re-evaluates stale/expired even if the request hangs
      _refresh();
    });
  }

  Future<void> _refreshIndex() async {
    try {
      index = await _stationsCache.refresh();
      error = null;
    } on DataUnavailable {
      if (index == null) error = "Couldn't load the station list. Check your connection.";
    }
    if (_disposed) return;
    _resolveStation();
    _notify();
  }

  Future<void> _locate({bool requestPermission = false}) async {
    final gen = ++_locationGen;
    _locating = true;
    final c = await _location.current(requestPermission: requestPermission);
    if (gen != _locationGen || manualStation || _disposed) return;
    _locating = false;
    if (c != null) coords = c;
    _resolveStation();
    _notify();
  }

  void _resolveStation() {
    final idx = index;
    if (idx == null) return;
    if (manualStation && station != null) return;
    final c = coords;
    if (c != null) {
      _setStation(nearestStation(idx.stations, c.$1, c.$2).$1);
      return;
    }
    final saved = _prefs.getString(_lastStationKey);
    final s = saved == null ? null : idx.byCrs(saved);
    if (s != null) {
      _setStation(s);
    } else if (station == null && !_locating) {
      needsStationPick = true; // only once the location attempt has failed
    }
  }

  void _setStation(Station s) {
    final c = coords;
    distanceMeters = c == null || manualStation ? null : haversineMeters(c.$1, c.$2, s.lat, s.lon);
    needsStationPick = false;
    if (station?.crs == s.crs) return;
    station = s;
    _stationGen++;
    board = null;
    _lastFailed = false;
    _prefs.setString(_lastStationKey, s.crs);
    filters = _savedFilters(s.crs);
    _refresh();
  }

  Set<String> _savedFilters(String crs) {
    try {
      return {...(jsonDecode(_prefs.getString(_filtersKey(crs)) ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  /// Fetches the current station's board. One request per station at a time; an answer is
  /// applied only if the user is still on the station it was asked for.
  Future<void> _refresh() {
    final s = station;
    if (s == null || _disposed) return Future.value();
    if (_inFlightCrs == s.crs && _inFlight != null) return _inFlight!;
    if (rateLimited) {
      _notify();
      return Future.value();
    }
    final gen = _stationGen;
    final crs = s.crs;
    late final Future<void> f;
    f = _fetch(crs, gen).whenComplete(() {
      if (identical(_inFlight, f)) {
        _inFlight = null;
        _inFlightCrs = null;
      }
    });
    _inFlight = f;
    _inFlightCrs = crs;
    return f;
  }

  Future<void> _fetch(String crs, int gen) async {
    Board? b;
    var limited = false;
    try {
      b = await _departures.fetch(crs);
    } on RateLimited {
      limited = true;
    } on DeparturesUnavailable {
      // keep the last board; stale/expired say how old it is
    }
    if (_disposed || gen != _stationGen || station?.crs != crs) return;
    if (b != null) {
      board = b;
      _lastFailed = false;
      _rateLimitedUntil = null;
    } else {
      _lastFailed = true;
      if (limited) _rateLimitedUntil = now().add(rateLimitBackoff);
    }
    _notify();
  }
}

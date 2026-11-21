// Private fields set from public named parameters: initializing formals can't be private.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_controller.dart' show PeriodicTimerFactory;
import '../data/departures.dart';
import '../domain/position.dart';
import 'follow_logic.dart';
import 'follower.dart';

/// The followed train as the home screen shows it, kept fresh while the app is in the foreground:
/// its board reading (from the board on screen when that is its station, else polled every
/// [boardEvery]) and where it is (polled every [positionEvery], only with a Darwin service id).
class FollowTracker extends ChangeNotifier {
  FollowTracker({
    required Follower follower,
    required Listenable screen,
    required Board? Function() screenBoard,
    required Future<Board> Function(String crs) fetchBoard,
    required Future<ServiceDetails> Function(String serviceId) fetchService,
    required DateTime Function() clock,
    PeriodicTimerFactory periodic = Timer.periodic,
  })  : _follower = follower,
        _screen = screen,
        _screenBoard = screenBoard,
        _fetchBoard = fetchBoard,
        _fetchService = fetchService,
        _clock = clock,
        _periodic = periodic {
    _follower.addListener(_onFollow);
    _screen.addListener(_onScreen);
    _onFollow();
  }

  static const boardEvery = Duration(seconds: 30);
  static const positionEvery = Duration(seconds: 60);

  final Follower _follower;
  final Listenable _screen;
  final Board? Function() _screenBoard;
  final Future<Board> Function(String crs) _fetchBoard;
  final Future<ServiceDetails> Function(String serviceId) _fetchService;
  final DateTime Function() _clock;
  final PeriodicTimerFactory _periodic;

  FollowedTrain? _train;
  Departure? _departure;
  TrainPosition? _position;
  DateTime? _positionAt;
  Timer? _timer;
  bool _foreground = true;
  bool _busy = false;
  bool _disposed = false;

  /// The followed train; null when nothing is followed.
  FollowedTrain? get train => _train;

  /// Its latest board reading; null until one is known.
  Departure? get departure => _departure;

  /// Where it is; null when unknown.
  TrainPosition? get position => _position;

  void onForeground() {
    _foreground = true;
    _restart();
  }

  void onBackground() {
    _foreground = false;
    _stopTimer();
  }

  void _onFollow() {
    final t = _follower.current;
    if (t == _train) return;
    _train = t;
    _departure = null;
    _position = null;
    _positionAt = null;
    _restart();
    _notify();
  }

  void _onScreen() {
    final t = _train, b = _screenBoard();
    if (t == null || b == null || b.crs != t.crs) return;
    final d = findFollowed(b, t);
    if (d != null && d != _departure) {
      _departure = d;
      _notify();
    }
  }

  void _restart() {
    _stopTimer();
    if (_train == null || !_foreground || _disposed) return;
    _timer = _periodic(boardEvery, (_) => _tick());
    _tick();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final t = _train;
    if (t == null || _busy) return;
    _busy = true;
    try {
      final onScreen = _screenBoard();
      if (onScreen != null && onScreen.crs == t.crs) {
        _onScreen();
      } else {
        try {
          final d = findFollowed(await _fetchBoard(t.crs), t);
          if (t != _train) return;
          if (d != null) _departure = d;
        } catch (_) {
          // keep the last reading
        }
      }
      final sid = t.serviceId, now = _clock(), last = _positionAt;
      if (sid != null && (last == null || now.difference(last) >= positionEvery || now.isBefore(last))) {
        _positionAt = now;
        try {
          final p = (await _fetchService(sid)).position;
          if (t != _train) return;
          _position = p ?? _position;
        } catch (_) {
          // keep the last position
        }
      }
      _notify();
    } finally {
      _busy = false;
      // Followed another train while this ran: read it now, not at the next timer tick.
      if (_train != null && _train != t && !_disposed) unawaited(_tick());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    _follower.removeListener(_onFollow);
    _screen.removeListener(_onScreen);
    super.dispose();
  }
}

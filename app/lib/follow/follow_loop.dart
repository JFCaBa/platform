import '../data/departures.dart';
import '../domain/departure_text.dart';
import '../domain/position.dart';
import 'follow_logic.dart';

const followMaxDuration = Duration(hours: 3);
const cancelledLinger = Duration(minutes: 2);

/// One poll per [tick] of the followed train's board: alerts on changes, keeps the ongoing
/// text current and says when following should end. Driven by the foreground service.
class FollowLoop {
  FollowLoop({
    required this.train,
    required this.startedAt,
    required this.fetch,
    required this.alert,
    required this.ongoing,
    required this.clock,
    this.fetchService,
  });

  static const positionEvery = Duration(seconds: 60);

  final FollowedTrain train;
  final DateTime startedAt;
  final Future<Board> Function(String crs) fetch;
  final Future<void> Function(String title, String body) alert;
  final Future<void> Function(String title, String text) ongoing;
  final DateTime Function() clock;

  /// Where the train is, at most every [positionEvery]; only for a train with a service id.
  final Future<ServiceDetails> Function(String serviceId)? fetchService;
  TrainPosition? _position;
  DateTime? _positionAt;

  Departure? _last;
  DateTime? _cancelledAt;
  DateTime? _pausedUntil;
  int _missing = 0;
  bool _busy = false;

  bool _expired(DateTime now) =>
      !now.isBefore(startedAt.add(followMaxDuration)) ||
      (_cancelledAt != null && !now.isBefore(_cancelledAt!.add(cancelledLinger)));

  /// False when following must stop.
  Future<bool> tick() async {
    if (_busy) return true;
    if (_expired(clock())) return false;
    final paused = _pausedUntil;
    if (paused != null && clock().isBefore(paused)) return true;
    _busy = true;
    try {
      final Board b;
      try {
        b = await fetch(train.crs);
      } on RateLimited {
        _pausedUntil = clock().add(rateLimitBackoff);
        return true;
      } catch (_) {
        return true; // offline or server trouble: try again next tick
      }
      final d = findFollowed(b, train);
      if (d == null) return ++_missing < 2;
      _missing = 0;
      final before = _last;
      _last = d;
      _cancelledAt = isCancelled(d) ? (_cancelledAt ?? clock()) : null; // Darwin can take a cancellation back
      if (before != null) {
        for (final body in changes(before, d)) {
          await _safely(() => alert(train.title, body));
        }
      }
      await _refreshPosition();
      final now = clock();
      await _safely(() => ongoing(ongoingTitle(train, d), ongoingText(d, now.toUtc(), _position)));
      return !_expired(clock());
    } finally {
      _busy = false;
    }
  }

  Future<void> _refreshPosition() async {
    final sid = train.serviceId, fetch = fetchService, now = clock(), last = _positionAt;
    if (sid == null || fetch == null) return;
    if (last != null && now.difference(last) < positionEvery && !now.isBefore(last)) return;
    _positionAt = now;
    try {
      _position = (await fetch(sid)).position ?? _position;
    } catch (_) {
      // keep the last position
    }
  }

  Future<void> _safely(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // a notification that could not be shown must not end the follow
    }
  }
}

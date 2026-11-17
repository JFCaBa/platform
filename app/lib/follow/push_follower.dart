import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'follow_logic.dart';
import 'follow_loop.dart';
import 'follower.dart';
import 'push_token.dart';

const _key = 'push_follow';
const _timeout = Duration(seconds: 10);

/// iOS: the server follows the train and sends push alerts; the app only registers and unregisters.
class PushFollower extends ChangeNotifier implements Follower {
  PushFollower._(this._client, this._prefs, this._push, this._baseUrl, this._clock) {
    _current = _saved()?.train;
  }

  /// Call once, before runApp. The saved follow shows at once; the refresh with the server runs in
  /// the background, so a slow network never delays the app's start.
  static Future<PushFollower> create({
    required http.Client client,
    required SharedPreferences prefs,
    required PushToken push,
    String baseUrl = apiBaseUrl,
    DateTime Function() clock = DateTime.now,
  }) async {
    final f = PushFollower._(client, prefs, push, baseUrl, clock);
    unawaited(f.sync());
    return f;
  }

  final http.Client _client;
  final SharedPreferences _prefs;
  final PushToken _push;
  final String _baseUrl;
  final DateTime Function() _clock;

  FollowedTrain? _current;
  Future<void> _queue = Future.value();

  /// Bumped by every follow() and stop(): an operation that sees a newer value was superseded and
  /// must not change the state.
  int _gen = 0;

  /// What the server last accepted (a POST answered 200), even from a superseded operation, until
  /// that token is deleted: so a stop or a later follow can always clean it up.
  _Saved? _registered;

  @override
  FollowedTrain? get current => _current;

  /// One operation at a time, so the server sees requests in the order they were made and the
  /// saved state only changes inside the queue.
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _queue.then((_) => f());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  @override
  Future<bool> follow(FollowedTrain t) {
    final gen = ++_gen;
    return _serial(() async {
      if (gen != _gen) return true; // a later follow or stop already replaced this one
      if (!await _push.requestPermission()) return false;
      final token = await _push.token();
      // Allowed, but the device couldn't register: not something Settings can fix.
      if (token == null) throw const FollowFailed(FollowFailure.network);
      final env = await _push.environment();
      if (gen != _gen) return true;
      final old = _saved();
      if (old != null && old.token != token) {
        // Token rotated: the old registration and the train shown for it are gone either way.
        await _delete(old.token);
        await _clear();
      }
      final stray = _registered;
      if (stray != null && stray.token != token) await _delete(stray.token);
      final s = _Saved(t, _clock().millisecondsSinceEpoch, token, env);
      final code = await _post(s);
      if (gen != _gen) return true;
      if (code == 200) {
        await _save(s);
        if (gen != _gen) return true;
        _set(t);
        return true;
      }
      await _dropStray();
      throw FollowFailed(code == 410 ? FollowFailure.gone : FollowFailure.network);
    });
  }

  @override
  Future<void> stop() {
    ++_gen;
    // Forget the follow on disk right away: if iOS kills the app while the queue waits, a relaunch
    // must not bring it back.
    final saved = _saved()?.token;
    final removed = _prefs.remove(_key);
    _set(null);
    return _serial(() async {
      await removed;
      // _registered is read here, once any earlier POST has answered.
      final tokens = {?saved, ?_saved()?.token, ?_registered?.token};
      await _prefs.remove(_key); // again: a pending follow's save may have rewritten it
      for (final t in tokens) {
        await _delete(t);
      }
    });
  }

  @override
  Future<void> sync() {
    final gen = _gen;
    return _serial(() async {
      if (gen != _gen) return;
      final s = _saved();
      if (s == null) return _set(null);
      _set(s.train);
      final started = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      if (!_clock().isBefore(started.add(followMaxDuration))) {
        await _clear();
        await _delete(s.token);
        return;
      }
      final token = await _push.token();
      if (token == null || gen != _gen) return; // can't refresh now: keep the follow
      final env = await _push.environment();
      if (gen != _gen) return;
      if (token != s.token) await _delete(s.token);
      final fresh = _Saved(s.train, s.startedAt, token, env);
      final code = await _post(fresh);
      if (gen != _gen) return;
      if (code == 410) return _clear();
      if (token != s.token || env != s.env) await _save(fresh);
    });
  }

  @override
  Future<void> openSettings() => _push.openSettings();

  /// After a failed follow: the server may still hold a registration from a superseded follow that
  /// no saved state accounts for. Delete it, and any saved follow it replaced on the server.
  Future<void> _dropStray() async {
    final stray = _registered;
    final saved = _saved();
    if (stray == null || stray == saved) return;
    await _delete(stray.token);
    if (saved != null && saved.token == stray.token) await _clear();
  }

  /// POST /follow; the HTTP status, or null on a network error.
  Future<int?> _post(_Saved s) async {
    try {
      final r = await _client
          .post(Uri.parse('$_baseUrl/follow'), headers: _headers, body: jsonEncode(s.body()))
          .timeout(_timeout);
      if (r.statusCode == 200) _registered = s;
      return r.statusCode;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort DELETE /follow: the server also ends follows on its own after 3 h.
  Future<void> _delete(String token) async {
    if (_registered?.token == token) _registered = null;
    try {
      await _client
          .delete(Uri.parse('$_baseUrl/follow'), headers: _headers, body: jsonEncode({'token': token}))
          .timeout(_timeout);
    } catch (_) {}
  }

  static const _headers = {'User-Agent': userAgent, 'Content-Type': 'application/json'};

  _Saved? _saved() {
    final j = _prefs.getString(_key);
    if (j == null) return null;
    try {
      return _Saved.fromJson(jsonDecode(j) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(_Saved s) => _prefs.setString(_key, jsonEncode(s.toJson()));

  Future<void> _clear() async {
    await _prefs.remove(_key);
    _set(null);
  }

  void _set(FollowedTrain? t) {
    if (t == _current) return;
    _current = t;
    notifyListeners();
  }
}

class _Saved {
  const _Saved(this.train, this.startedAt, this.token, this.env);
  final FollowedTrain train;
  final int startedAt; // epoch ms
  final String token;
  final String env;

  factory _Saved.fromJson(Map<String, dynamic> j) => _Saved(FollowedTrain.fromJson(j['train'] as Map<String, dynamic>),
      j['startedAt'] as int, j['token'] as String, j['env'] as String);

  Map<String, dynamic> toJson() => {'train': train.toJson(), 'startedAt': startedAt, 'token': token, 'env': env};

  Map<String, dynamic> body() => {'token': token, 'env': env, ...train.toJson(), 'startedAt': startedAt};

  @override
  bool operator ==(Object other) =>
      other is _Saved &&
      other.train == train &&
      other.startedAt == startedAt &&
      other.token == token &&
      other.env == env;

  @override
  int get hashCode => Object.hash(train, startedAt, token, env);
}

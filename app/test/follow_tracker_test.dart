import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/data/departures.dart';
import 'package:platform_app/domain/position.dart';
import 'package:platform_app/follow/follow_logic.dart';
import 'package:platform_app/follow/follow_tracker.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support.dart';

Board board(String crs, {String? platform = '10', String? sid = 'S1'}) => Board.fromJson(jsonDecode(boardJson(
    crs, DateTime.utc(2026, 11, 21, 16, 30),
    services: [service('16:42', platform: platform, destination: 'Peterborough', serviceId: sid)])) as Map<String, dynamic>);

class Screen extends ChangeNotifier {
  Board? board;
  void show(Board? b) {
    board = b;
    notifyListeners();
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late FakeFollower follower;
  late Screen screen;
  late TimerLog timers;
  late DateTime now;
  late List<String> boardCalls, serviceCalls;
  late FollowTracker tracker;

  const pbo = FollowedTrain(crs: 'SVG', std: '16:42', destination: 'Peterborough', serviceId: 'S1');

  setUp(() {
    follower = FakeFollower();
    screen = Screen();
    timers = TimerLog();
    now = DateTime.utc(2026, 11, 21, 16, 30);
    boardCalls = [];
    serviceCalls = [];
    tracker = FollowTracker(
      follower: follower,
      screen: screen,
      screenBoard: () => screen.board,
      fetchBoard: (crs) async {
        boardCalls.add(crs);
        return board(crs);
      },
      fetchService: (id) async {
        serviceCalls.add(id);
        return const ServiceDetails(portions: [], position: PassedStop('Stevenage', '16:31', 2));
      },
      clock: () => now,
      periodic: timers.create,
    );
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('idle while nothing is followed', () async {
    await settle();
    expect(boardCalls, isEmpty);
    expect(serviceCalls, isEmpty);
    expect(timers.active, 0);
    expect(tracker.departure, isNull);
  });

  test('polls the followed station board every 30 s and the position every 60 s', () async {
    screen.show(board('KGX'));
    await follower.follow(pbo);
    await settle();
    expect(boardCalls, ['SVG']);
    expect(serviceCalls, ['S1']);
    expect(tracker.departure!.platform, '10');
    expect(tracker.position, const PassedStop('Stevenage', '16:31', 2));
    now = now.add(const Duration(seconds: 30));
    timers.fireActive();
    await settle();
    expect(boardCalls, ['SVG', 'SVG']);
    expect(serviceCalls, ['S1']);
    now = now.add(const Duration(seconds: 30));
    timers.fireActive();
    await settle();
    expect(serviceCalls, ['S1', 'S1']);
  });

  test('uses the board on screen when it is the followed station', () async {
    screen.show(board('SVG', platform: '4'));
    await follower.follow(pbo);
    await settle();
    expect(boardCalls, isEmpty);
    expect(tracker.departure!.platform, '4');
    screen.show(board('SVG', platform: '5'));
    expect(tracker.departure!.platform, '5');
  });

  test('no service id: no position lookups', () async {
    await follower.follow(const FollowedTrain(crs: 'SVG', std: '16:42', destination: 'Peterborough'));
    await settle();
    expect(serviceCalls, isEmpty);
    expect(tracker.position, isNull);
  });

  test('stops on unfollow and in the background, resumes in the foreground', () async {
    await follower.follow(pbo);
    await settle();
    await follower.stop();
    await settle();
    expect(timers.active, 0);
    expect(tracker.departure, isNull);
    await follower.follow(pbo);
    await settle();
    tracker.onBackground();
    expect(timers.active, 0);
    final before = boardCalls.length;
    tracker.onForeground();
    await settle();
    expect(timers.active, 1);
    expect(boardCalls.length, before + 1);
  });

  test('a failed fetch keeps what was known', () async {
    var fail = false;
    final t = FollowTracker(
      follower: follower,
      screen: screen,
      screenBoard: () => screen.board,
      fetchBoard: (crs) async => fail ? throw const DeparturesUnavailable('x') : board(crs),
      fetchService: (id) async => fail ? throw const DeparturesUnavailable('x') : const ServiceDetails(portions: [], position: StartsHere()),
      clock: () => now,
      periodic: timers.create,
    );
    await follower.follow(pbo);
    await settle();
    fail = true;
    now = now.add(const Duration(seconds: 60));
    timers.fireActive();
    await settle();
    expect(t.departure, isNotNull);
    expect(t.position, const StartsHere());
  });
}

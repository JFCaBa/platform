import 'package:flutter/foundation.dart';

import 'follow_logic.dart';

/// Follows at most one train; null on platforms without background following.
abstract class Follower implements Listenable {
  FollowedTrain? get current;

  /// Starts following [t], replacing any other train. False when notifications are not allowed.
  Future<bool> follow(FollowedTrain t);

  Future<void> stop();

  /// Re-reads the follow state, e.g. after the app comes back to the foreground.
  Future<void> sync();
}

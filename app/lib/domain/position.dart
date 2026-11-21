import '../data/departures.dart';
import 'departure_text.dart';

/// Where a train is, from the API's `position` (Darwin's stops before this station).
/// Texts match the server's `live.py`, which feeds the Live Activity.
sealed class TrainPosition {
  const TrainPosition();

  /// Null when missing or not one of the three shapes.
  static TrainPosition? fromJson(Object? j) {
    if (j is! Map) return null;
    if (j['startsHere'] == true) return const StartsHere();
    final origin = j['notStarted'];
    if (origin is String && origin.isNotEmpty) return NotStarted(origin);
    final stop = j['lastStop'], at = j['lastAt'], away = j['stopsAway'];
    if (stop is String && stop.isNotEmpty && away is int && away >= 1) {
      return PassedStop(stop, at is String && hhmm.hasMatch(at) ? at : null, away);
    }
    return null;
  }
}

/// The last stop the train has left, and how many stops until this one (1 = next stop is here).
class PassedStop extends TrainPosition {
  const PassedStop(this.name, this.at, this.stopsAway);
  final String name;
  final String? at;
  final int stopsAway;

  @override
  bool operator ==(Object other) =>
      other is PassedStop && other.name == name && other.at == at && other.stopsAway == stopsAway;

  @override
  int get hashCode => Object.hash(name, at, stopsAway);
}

/// Not yet left its first stop.
class NotStarted extends TrainPosition {
  const NotStarted(this.origin);
  final String origin;

  @override
  bool operator ==(Object other) => other is NotStarted && other.origin == origin;

  @override
  int get hashCode => origin.hashCode;
}

/// The train starts at this station.
class StartsHere extends TrainPosition {
  const StartsHere();

  @override
  bool operator ==(Object other) => other is StartsHere;

  @override
  int get hashCode => 0;
}

/// "left Stevenage 16:31"
String _left(PassedStop p) => p.at == null ? 'left ${p.name}' : 'left ${p.name} ${p.at}';

/// "2 stops away · left Stevenage 16:31", "Next stop: here · left Hitchin 16:38",
/// "Not yet left London Kings Cross", "Starts here"; null when unknown.
String? whereText(TrainPosition? p) => switch (p) {
      null => null,
      StartsHere() => 'Starts here',
      NotStarted(:final origin) => 'Not yet left $origin',
      PassedStop(stopsAway: 1) && final s => 'Next stop: here · ${_left(s)}',
      PassedStop(:final stopsAway) && final s => '$stopsAway stops away · ${_left(s)}',
    };

/// The short form for the Android notification: "2 stops away (left Stevenage)", "Next stop: here
/// (left Hitchin)"; the other shapes as in [whereText].
String? whereShort(TrainPosition? p) => switch (p) {
      PassedStop(stopsAway: 1) && final s => 'Next stop: here (left ${s.name})',
      PassedStop(:final stopsAway) && final s => '$stopsAway stops away (left ${s.name})',
      _ => whereText(p),
    };

/// The Live Activity's content state (twin of the server's `content_state`): `departs` is the
/// expected departure in epoch seconds, null when Darwin only says "Delayed" or it is cancelled.
Map<String, Object?> contentState(Departure d, TrainPosition? p, DateTime nowUtc) {
  final cancelled = isCancelled(d);
  final at = cancelled ? null : departureAt(d, nowUtc);
  return {
    'departs': at == null ? null : at.millisecondsSinceEpoch ~/ 1000,
    'status': statusText(d),
    'platform': d.platform,
    'where': cancelled ? null : whereText(p),
    'cancelled': cancelled,
  };
}

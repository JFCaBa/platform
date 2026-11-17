import '../data/departures.dart';
import '../domain/departure_text.dart';

/// The one train being followed: its station, the board's scheduled time and destination and,
/// when the API gives it, Darwin's id for the train.
class FollowedTrain {
  const FollowedTrain({required this.crs, required this.std, required this.destination, this.serviceId});

  final String crs;
  final String std;
  final String destination;
  final String? serviceId;

  factory FollowedTrain.fromJson(Map<String, dynamic> j) => FollowedTrain(
      crs: j['crs'] as String,
      std: j['std'] as String,
      destination: j['destination'] as String,
      serviceId: j['serviceId'] as String?);

  Map<String, dynamic> toJson() =>
      {'crs': crs, 'std': std, 'destination': destination, if (serviceId != null) 'serviceId': serviceId};

  /// Same train on its station's board, whatever its platform or expected time: by id when both
  /// sides have one, else by scheduled time and destination.
  bool matches(Departure d) {
    final id = serviceId, other = d.serviceId;
    if (id != null && other != null) return id == other;
    return d.std == std && d.destination == destination;
  }

  String get title => '$std to $destination';

  @override
  bool operator ==(Object other) =>
      other is FollowedTrain &&
      other.crs == crs &&
      other.std == std &&
      other.destination == destination &&
      other.serviceId == serviceId;

  @override
  int get hashCode => Object.hash(crs, std, destination, serviceId);
}

Departure? findFollowed(Board b, FollowedTrain t) {
  if (b.crs != t.crs) return null;
  for (final d in b.services) {
    if (t.matches(d)) return d;
  }
  return null;
}

/// "08:12 to Cardiff Central · Plat 3 · On time"
String ongoingText(FollowedTrain t, Departure d) {
  final status = statusText(d);
  return [t.title, ?platformText(d), if (status.isNotEmpty) status].join(' · ');
}

/// What changed from one reading to the next, as alert texts: platform first, then time.
/// A newly cancelled train gives only the cancellation.
List<String> changes(Departure before, Departure after) {
  if (isCancelled(after)) {
    if (isCancelled(before)) return const [];
    final reason = after.cancelReason;
    return [reason == null || reason.isEmpty ? 'Cancelled' : 'Cancelled: $reason'];
  }
  final out = <String>[];
  final p0 = before.platform, p1 = after.platform;
  if (p1 != null && p1 != p0) out.add(p0 == null ? 'Platform $p1' : 'Platform changed: $p0 → $p1');
  final e1 = after.etd;
  if (e1 != null && e1 != before.etd) {
    if (hhmm.hasMatch(e1)) {
      out.add('Now expected $e1');
    } else if (e1 == 'On time' && before.etd != null) {
      out.add('Now on time');
    } else if (e1 == 'Delayed') {
      out.add('Delayed');
    }
  }
  return out;
}

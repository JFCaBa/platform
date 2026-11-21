import 'package:timezone/timezone.dart' as tz;

import '../data/departures.dart';

final hhmm = RegExp(r'^\d{2}:\d{2}$');

bool isCancelled(Departure d) => d.cancelled || d.etd == 'Cancelled';

/// "Cancelled" | "On time" | "Exp 10:22" | "Delayed" | "" (no estimate).
String statusText(Departure d) {
  if (isCancelled(d)) return 'Cancelled';
  final etd = d.etd;
  if (etd == null) return '';
  if (hhmm.hasMatch(etd)) return 'Exp $etd';
  return etd; // "On time", "Delayed"
}

String? platformText(Departure d) => d.platform == null ? null : 'Plat ${d.platform}';

/// Running late: an expected time other than the scheduled one, or "Delayed".
bool isLate(Departure d) =>
    !isCancelled(d) && (d.etd == 'Delayed' || (d.etd != null && hhmm.hasMatch(d.etd!) && d.etd != d.std));

/// The first train that will run: it goes in the large card. Null if all are cancelled.
int? nextTrainIndex(List<Departure> ds) {
  for (var i = 0; i < ds.length; i++) {
    if (!isCancelled(ds[i])) return i;
  }
  return null;
}

final _london = tz.getLocation('Europe/London');

/// The train's expected (else scheduled) London time as an instant; null when Darwin only says
/// "Delayed". Times on a board are within a few hours: of the departure on yesterday's, today's or
/// tomorrow's London date, the instant nearest to [nowUtc] wins (right across midnight and clock
/// changes).
DateTime? departureAt(Departure d, DateTime nowUtc) {
  final etd = d.etd;
  if (etd == 'Delayed') return null;
  final t = etd != null && hhmm.hasMatch(etd) ? etd : d.std;
  if (!hhmm.hasMatch(t)) return null;
  final h = int.parse(t.substring(0, 2)), m = int.parse(t.substring(3));
  final today = tz.TZDateTime.from(nowUtc, _london);
  DateTime? best;
  for (final day in [-1, 0, 1]) {
    final at = tz.TZDateTime(_london, today.year, today.month, today.day + day, h, m);
    if (best == null || at.difference(nowUtc).abs() < best.difference(nowUtc).abs()) best = at;
  }
  return best!.toUtc();
}

/// Minutes from [nowUtc] to [departureAt], floored; null when unknown.
int? minutesUntil(Departure d, DateTime nowUtc) {
  final at = departureAt(d, nowUtc);
  return at == null ? null : (at.difference(nowUtc).inSeconds / 60).floor();
}

/// "Due", "1 min", "12 min", "1 h 05".
String waitText(int minutes) {
  if (minutes <= 0) return 'Due';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

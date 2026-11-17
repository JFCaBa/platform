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

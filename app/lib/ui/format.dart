import 'package:timezone/timezone.dart' as tz;

/// "HH:mm" in London time, whatever the phone's time zone.
String londonHhmm(DateTime utc) {
  final t = tz.TZDateTime.from(utc, tz.getLocation('Europe/London'));
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String formatDistance(double m) =>
    m < 1000 ? '${(m / 10).round() * 10} m' : (m < 100000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${(m / 1000).round()} km');

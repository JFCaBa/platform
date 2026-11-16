import 'package:material_ui/material_ui.dart';

import '../data/departures.dart';

final _hhmm = RegExp(r'^\d{2}:\d{2}$');

/// "Cancelled" | "On time" | "Exp 10:22" | "Delayed" | "" (no estimate).
String statusText(Departure d) {
  if (d.cancelled || d.etd == 'Cancelled') return 'Cancelled';
  final etd = d.etd;
  if (etd == null) return '';
  if (_hhmm.hasMatch(etd)) return 'Exp $etd';
  return etd; // "On time", "Delayed"
}

String? platformText(Departure d) => d.platform == null ? null : 'Plat ${d.platform}';

/// One departure: scheduled time and status on the left, destination in the middle,
/// platform large on the right. Times are shown exactly as the API gives them.
class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d, {super.key});
  final Departure d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cancelled = d.cancelled || d.etd == 'Cancelled';
    final status = statusText(d);
    final late = cancelled || d.etd == 'Delayed' || (d.etd != null && _hhmm.hasMatch(d.etd!));
    final reason = cancelled ? d.cancelReason : d.delayReason;
    final plat = platformText(d);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 76,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.std,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                  color: cancelled ? scheme.onSurfaceVariant : null,
                )),
            if (status.isNotEmpty)
              Text(status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: late ? scheme.error : scheme.onSurfaceVariant,
                    fontWeight: late ? FontWeight.w600 : null,
                  )),
          ]),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.destination, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (d.via != null) Text(d.via!, style: muted),
            if (d.operator != null) Text(d.operator!, style: muted),
            if (reason != null) Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          ]),
        ),
        const SizedBox(width: 8),
        if (plat != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cancelled ? scheme.surfaceContainerHighest : scheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(plat,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cancelled ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
                )),
          ),
      ]),
    );
  }
}

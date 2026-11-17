import 'package:material_ui/material_ui.dart';

import '../data/departures.dart';
import '../domain/departure_text.dart';

export '../domain/departure_text.dart' show statusText, platformText;

/// Width that fits the widest time and status at the phone's text size, so the column
/// never wraps ("16:2" / "3") and destinations line up in every row.
double timeColumnWidth(BuildContext context, TextStyle? time, TextStyle? status) {
  final scaler = MediaQuery.textScalerOf(context);
  double w(String s, TextStyle? style) {
    final p = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)
      ..layout();
    final width = p.width;
    p.dispose();
    return width;
  }

  const gap = 12.0; // space before the destination
  return [w('00:00', time), for (final s in ['Exp 00:00', 'Cancelled', 'On time', 'Delayed']) w(s, status)]
          .reduce((a, b) => a > b ? a : b) +
      gap;
}

/// One departure: scheduled time and status on the left, destination in the middle,
/// platform large on the right. Times are shown exactly as the API gives them.
class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d, {super.key, this.followed = false, this.onTap});
  final Departure d;

  /// This is the train being followed: shows a bell.
  final bool followed;

  /// Null: the row is not tappable.
  final VoidCallback? onTap;

  /// Above this the time column and the platform badge no longer fit on a narrow phone.
  static const maxTextScale = 1.5;

  @override
  Widget build(BuildContext context) {
    final row = MediaQuery.withClampedTextScaling(maxScaleFactor: maxTextScale, child: Builder(builder: _row));
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cancelled = isCancelled(d);
    final status = statusText(d);
    final late = cancelled || d.etd == 'Delayed' || (d.etd != null && hhmm.hasMatch(d.etd!));
    final reason = cancelled ? d.cancelReason : d.delayReason;
    final plat = platformText(d);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final stdStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
      decoration: cancelled ? TextDecoration.lineThrough : null,
      color: cancelled ? scheme.onSurfaceVariant : null,
    );
    final statusStyle = theme.textTheme.bodySmall?.copyWith(
      color: late ? scheme.error : scheme.onSurfaceVariant,
      fontWeight: late ? FontWeight.w600 : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: timeColumnWidth(context, stdStyle, statusStyle?.copyWith(fontWeight: FontWeight.w600)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.std, style: stdStyle, maxLines: 1, softWrap: false),
            if (status.isNotEmpty) Text(status, style: statusStyle, maxLines: 1, softWrap: false),
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
        if (followed)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Icon(Icons.notifications_active, size: 20, color: scheme.primary, semanticLabel: 'Following'),
          ),
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

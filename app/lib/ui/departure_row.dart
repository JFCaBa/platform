import 'package:material_ui/material_ui.dart';

import '../data/departures.dart';
import '../domain/departure_text.dart';

export '../domain/departure_text.dart' show statusText, platformText, isLate, nextTrainIndex, minutesUntil, waitText;

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

/// Amber for running late: a delay is a warning, red is kept for cancellations.
Color lateColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);

/// Green for "live".
Color goodColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);

/// The platform: a compact "Plat 9" pill in a row, a large tile in the next-train card.
/// Nothing in a row before Darwin gives one; the card says it is not out yet.
class PlatformBadge extends StatelessWidget {
  const PlatformBadge(this.d, {super.key, this.large = false});
  final Departure d;
  final bool large;

  String? get platform => d.platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cancelled = isCancelled(d);
    final bg = cancelled ? scheme.surfaceContainerHighest : scheme.primary;
    final fg = cancelled ? scheme.onSurfaceVariant : scheme.onPrimary;
    final p = d.platform;
    if (!large) {
      final text = platformText(d);
      if (text == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(
          platformText(d)!,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: fg),
        ),
      );
    }
    if (p == null) {
      return Container(
        width: 96,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          'Platform not yet shown',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Semantics(
      label: 'Platform $p',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 96),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Platform', style: theme.textTheme.labelMedium?.copyWith(color: fg)),
            Text(
              p,
              maxLines: 1,
              style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: fg, height: 1.1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status colour: red cancelled, amber late, muted otherwise.
Color _statusColor(BuildContext context, Departure d) => isCancelled(d)
    ? Theme.of(context).colorScheme.error
    : isLate(d)
    ? lateColor(context)
    : Theme.of(context).colorScheme.onSurfaceVariant;

/// The first train that runs, large: how long until it leaves and its platform, which is what
/// someone walking into the station wants. Tap for stops, long press to follow, like a row.
class NextTrainCard extends StatelessWidget {
  const NextTrainCard(this.d, {super.key, required this.nowUtc, this.followed = false, this.onTap, this.onLongPress});
  final Departure d;
  final DateTime nowUtc;
  final bool followed;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A followed train can be cancelled: then that is the headline, not a countdown.
    final cancelled = isCancelled(d);
    final mins = cancelled ? null : minutesUntil(d, nowUtc);
    final headline = cancelled ? 'Cancelled' : (mins == null ? 'Delayed' : waitText(mins));
    final status = statusText(d);
    final reason = cancelled ? d.cancelReason : d.delayReason;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final statusStyle = theme.textTheme.bodyMedium?.copyWith(
      color: _statusColor(context, d),
      fontWeight: isLate(d) ? FontWeight.w600 : null,
    );
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: DepartureRow.maxTextScale,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cancelled ? scheme.error : (mins == null ? lateColor(context) : null),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        children: [
                          Text(
                            d.std,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          if (status.isNotEmpty && status != headline) Text(status, style: statusStyle),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(d.destination, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      if (d.via != null) Text(d.via!, style: muted),
                      if (d.operator != null) Text(d.operator!, style: muted),
                      if (reason != null)
                        Text(
                          reason,
                          style: theme.textTheme.bodySmall?.copyWith(color: cancelled ? scheme.error : lateColor(context)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    PlatformBadge(d, large: true),
                    // Said in words: the followed train can sit above earlier trains in the list.
                    if (followed)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_active, size: 18, color: scheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              'Following',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One departure: scheduled time and status on the left, destination in the middle,
/// platform on the right. Times are shown exactly as the API gives them. Cancelled trains are dimmed.
class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d, {super.key, this.followed = false, this.onTap, this.onLongPress});
  final Departure d;

  /// This is the train being followed: shows a bell.
  final bool followed;

  /// Null: the row is not tappable.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Above this the time column and the platform badge no longer fit on a narrow phone.
  static const maxTextScale = 1.5;

  @override
  Widget build(BuildContext context) {
    final row = MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxTextScale,
      child: Builder(builder: _row),
    );
    return onTap == null && onLongPress == null ? row : InkWell(onTap: onTap, onLongPress: onLongPress, child: row);
  }

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cancelled = isCancelled(d);
    final late = isLate(d);
    final status = statusText(d);
    final reason = cancelled ? d.cancelReason : d.delayReason;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final stdStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
      decoration: cancelled ? TextDecoration.lineThrough : null,
      color: cancelled ? scheme.onSurfaceVariant : null,
    );
    final statusStyle = theme.textTheme.bodySmall?.copyWith(
      color: _statusColor(context, d),
      fontWeight: late || cancelled ? FontWeight.w600 : null,
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: timeColumnWidth(context, stdStyle, statusStyle?.copyWith(fontWeight: FontWeight.w600)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.std, style: stdStyle, maxLines: 1, softWrap: false),
                if (status.isNotEmpty) Text(status, style: statusStyle, maxLines: 1, softWrap: false),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.destination, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (d.via != null) Text(d.via!, style: muted),
                if (d.operator != null) Text(d.operator!, style: muted),
                if (reason != null)
                  Text(
                    reason,
                    style: theme.textTheme.bodySmall?.copyWith(color: cancelled ? scheme.error : lateColor(context)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (followed)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Icon(Icons.notifications_active, size: 20, color: scheme.primary, semanticLabel: 'Following'),
            ),
          PlatformBadge(d),
        ],
      ),
    );
    return cancelled ? Opacity(opacity: 0.55, child: content) : content;
  }
}

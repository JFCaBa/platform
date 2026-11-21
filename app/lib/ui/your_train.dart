import 'package:material_ui/material_ui.dart';

import '../data/departures.dart';
import '../domain/departure_text.dart';
import '../domain/position.dart';
import '../follow/follow_logic.dart';
import 'departure_row.dart';

/// The followed train while another station is on screen: what you'd glance at while waiting,
/// like a ride-hailing app's "your car" strip. Tap to open its station.
class YourTrainStrip extends StatelessWidget {
  const YourTrainStrip({super.key, required this.train, this.departure, this.position, required this.nowUtc, this.onTap});
  final FollowedTrain train;
  final Departure? departure;
  final TrainPosition? position;
  final DateTime nowUtc;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = departure;
    final cancelled = d != null && isCancelled(d);
    final mins = d == null || cancelled ? null : minutesUntil(d, nowUtc);
    final headline = d == null ? null : (cancelled ? 'Cancelled' : (mins == null ? 'Delayed' : waitText(mins)));
    final where = cancelled ? null : whereText(position);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: DepartureRow.maxTextScale,
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.notifications_active, color: scheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your train', style: muted?.copyWith(fontWeight: FontWeight.w700)),
                      Text(train.title,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (where != null) Text(where, style: muted, maxLines: 2),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (headline != null)
                      Text(
                        headline,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cancelled ? scheme.error : scheme.onPrimaryContainer,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    if (d != null) ...[const SizedBox(height: 4), PlatformBadge(d)],
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

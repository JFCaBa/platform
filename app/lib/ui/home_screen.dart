import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../config.dart';
import '../data/departures.dart';
import '../follow/follow_logic.dart';
import '../follow/follower.dart';
import '../domain/departure_text.dart';
import 'departure_row.dart';
import 'format.dart';
import 'station_picker.dart';

/// Loads the stops still ahead of a train, by Darwin service id.
typedef StopsFetcher = Future<List<List<Stop>>> Function(String serviceId);

/// Beyond this, the nearest station is probably not useful; say so.
const farFromStationMeters = 25000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.openUrl = _launchExternal, this.follower, this.fetchStops});
  final AppController controller;

  /// Null where trains cannot be followed (iOS for now): rows are then not tappable.
  final Follower? follower;

  /// Null: tapping a train shows no stops (tests that do not care).
  final StopsFetcher? fetchStops;

  /// Opens a web page; injectable for tests.
  final Future<void> Function(Uri) openUrl;

  static Future<void> _launchExternal(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open $url');
    }
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get controller => widget.controller;

  Future<void> _openPrivacy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.openUrl(Uri.parse(privacyUrl));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't open the privacy policy")));
    }
  }

  Future<void> _pick(BuildContext context) async {
    final index = controller.index;
    if (index == null) return;
    final crs = await pickStation(context, index, controller.coords);
    if (crs == useLocationChoice) {
      controller.useLocation();
    } else if (crs != null) {
      controller.chooseStation(crs);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([controller, ?widget.follower]),
        builder: (context, _) => Scaffold(body: SafeArea(child: _body(context))),
      );

  Widget _body(BuildContext context) {
    final c = controller;
    if (c.index == null) {
      if (c.error == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(c.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (c.retrying) const CircularProgressIndicator() else FilledButton(onPressed: c.retry, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final theme = Theme.of(context);
    final board = c.board;
    return RefreshIndicator(
      onRefresh: c.retry,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (c.station == null && !c.needsStationPick)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Finding your station…')]),
            )
          else if (c.station == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                const Text("We don't know where you are."),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => _pick(context), child: const Text('Choose station')),
              ]),
            )
          else ...[
            _header(context),
            if (!c.manualStation && (c.distanceMeters ?? 0) > farFromStationMeters)
              _Banner("You're ${formatDistance(c.distanceMeters!)} from the nearest station"),
            if (board == null && c.rateLimited)
              const _Banner('Busy right now. Trying again in a few minutes.')
            else if (board == null && c.loadFailed)
              _Banner("Couldn't load departures.", onRetry: c.retrying ? null : c.retry)
            else if (board == null)
              const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: Center(child: CircularProgressIndicator()))
            else
              ..._board(context, board),
          ],
          const SizedBox(height: 24),
          if (board != null) Text(board.attribution, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          Center(
            child: TextButton(
              onPressed: () => _openPrivacy(context),
              child: Text('Privacy', style: theme.textTheme.bodySmall?.copyWith(decoration: TextDecoration.underline)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final name = c.station!.name.isNotEmpty ? c.station!.name : (c.board?.name ?? c.station!.crs);
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(c.manualStation ? Icons.place_outlined : Icons.my_location, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
          ),
          if (c.distanceMeters != null) Text(formatDistance(c.distanceMeters!), style: theme.textTheme.bodyMedium),
          const Icon(Icons.expand_more),
        ]),
      ),
    );
  }

  /// The open train (one at a time) and its stops, loaded when it was opened.
  String? _openKey;
  Future<List<List<Stop>>>? _openStops;

  static String _key(Departure d) => d.serviceId ?? '${d.std}|${d.destination}';

  void _toggleOpen(Departure d) => setState(() {
        if (_openKey == _key(d)) {
          _openKey = null;
          _openStops = null;
          return;
        }
        _openKey = _key(d);
        final id = d.serviceId, fetch = widget.fetchStops;
        // ignore(): a failure that lands before the panel listens must still reach it, not the zone
        _openStops = id == null || fetch == null ? null : (fetch(id)..ignore());
      });

  Widget _row(BuildContext context, Board b, Departure d) {
    final follower = widget.follower;
    final current = follower?.current;
    final followed = current != null && current.crs == b.crs && current.matches(d);
    final t = FollowedTrain(crs: b.crs, std: d.std, destination: d.destination, serviceId: d.serviceId);
    void toggleFollow() => _toggleFollow(context, follower!, t, followed);
    final open = _openKey == _key(d);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DepartureRow(d,
          followed: followed,
          onTap: () => _toggleOpen(d),
          onLongPress: follower == null ? null : toggleFollow),
      if (open)
        _StopsPanel(
          stops: _openStops,
          followed: followed,
          onFollow: follower == null ? null : toggleFollow,
        ),
    ]);
  }

  List<Widget> _board(BuildContext context, Board b) {
    final c = controller;
    final updated = 'Last updated ${londonHhmm(b.generatedAt)}';
    return [
      if (c.rateLimited) const _Banner('Busy right now. Trying again in a few minutes.'),
      if (c.expired)
        _Banner(updated, onRetry: c.retrying || c.rateLimited ? null : c.retry)
      else if (c.stale && !c.rateLimited)
        _Banner(updated, onRetry: c.retrying ? null : c.retry),
      if (b.nrccMessages.isNotEmpty) _Alerts(b.nrccMessages, initiallyOpen: b.services.isEmpty),
      if (!c.expired) ...[
        _FilterChips(destinations: c.destinations, selected: c.filters, onToggle: c.toggleFilter, onClear: c.clearFilters),
        const Divider(),
        if (b.services.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No departures in the next 2 hours'))
        else if (c.visibleServices.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No trains to these destinations right now'))
        else
          for (final d in c.visibleServices) _row(context, b, d),
      ],
    ];
  }
}

Future<void> _toggleFollow(BuildContext context, Follower follower, FollowedTrain t, bool followed) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  if (followed) {
    await follower.stop();
    messenger.showSnackBar(const SnackBar(content: Text('Stopped following')));
    return;
  }
  final previous = follower.current;
  if (!await _follow(messenger, follower, t)) return;
  if (follower.current != t) return; // a later follow or stop replaced this one meanwhile
  messenger.showSnackBar(SnackBar(
    content: Text('Following ${t.title}'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () => previous == null ? follower.stop() : _follow(messenger, follower, previous),
    ),
  ));
}

/// Follows [t]; on failure shows why and returns false.
Future<bool> _follow(ScaffoldMessengerState messenger, Follower follower, FollowedTrain t) async {
  String? problem;
  try {
    if (!await follower.follow(t)) problem = _deniedText;
  } on FollowFailed catch (e) {
    problem = switch (e.reason) {
      FollowFailure.gone => 'That train has left',
      FollowFailure.network => "Couldn't follow: check your connection",
      FollowFailure.notifications => _deniedText,
    };
  }
  if (problem == null) return true;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(problem),
    action: problem == _deniedText ? SnackBarAction(label: 'Settings', onPressed: follower.openSettings) : null,
  ));
  return false;
}

const _deniedText = 'Allow notifications to follow a train';

/// Under an open train: follow button (where following works) and the stops still ahead.
class _StopsPanel extends StatelessWidget {
  const _StopsPanel({required this.stops, required this.followed, required this.onFollow});
  final Future<List<List<Stop>>>? stops;
  final bool followed;
  final VoidCallback? onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (onFollow != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: followed
                ? OutlinedButton.icon(
                    onPressed: onFollow, icon: const Icon(Icons.notifications_off), label: const Text('Stop following'))
                : FilledButton.tonalIcon(
                    onPressed: onFollow,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Follow this train')),
          ),
        if (stops == null)
          Text('Stops unavailable', style: muted)
        else
          FutureBuilder<List<List<Stop>>>(
            future: stops,
            builder: (context, snap) {
              if (snap.hasError) return Text('Stops unavailable', style: muted);
              if (!snap.hasData) {
                return const Padding(
                    padding: EdgeInsets.all(8), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)));
              }
              final portions = snap.data!;
              if (portions.isEmpty) return Text('No more stops', style: muted);
              final split = portions.length > 1;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final p in portions) ...[
                  if (split)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2),
                      child: Text('To ${p.last.name}',
                          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  for (final s in p) _StopLine(s),
                ],
              ]);
            },
          ),
      ]),
    );
  }
}

class _StopLine extends StatelessWidget {
  const _StopLine(this.s);
  final Stop s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final et = s.et;
    final status = s.cancelled
        ? 'Cancelled'
        : et != null && hhmm.hasMatch(et)
            ? 'Exp $et'
            : et == 'Delayed'
                ? 'Delayed'
                : '';
    final body = theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 56,
          child: Text(s.st,
              style: body?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: scheme.onSurfaceVariant,
              )),
        ),
        Expanded(
          child: Text(s.name,
              style: body?.copyWith(decoration: s.cancelled ? TextDecoration.lineThrough : null),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        if (status.isNotEmpty)
          Text(status, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.destinations, required this.selected, required this.onToggle, required this.onClear});
  final List<String> destinations;
  final Set<String> selected;
  final void Function(String) onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (destinations.length < 2 && selected.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        FilterChip(label: const Text('All'), selected: selected.isEmpty, onSelected: (_) => onClear()),
        for (final d in destinations)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilterChip(label: Text(d), selected: selected.contains(d), onSelected: (_) => onToggle(d)),
          ),
      ]),
    );
  }
}

/// Station messages from National Rail: one line, expanded on tap, so trains stay on the first screen.
class _Alerts extends StatefulWidget {
  const _Alerts(this.messages, {this.initiallyOpen = false});
  final List<String> messages;

  /// With no trains to show, the alerts are the answer (e.g. replacement buses).
  final bool initiallyOpen;

  @override
  State<_Alerts> createState() => _AlertsState();
}

class _AlertsState extends State<_Alerts> {
  late bool _open = widget.initiallyOpen;

  @override
  void didUpdateWidget(_Alerts old) {
    super.didUpdateWidget(old);
    if (widget.initiallyOpen && !old.initiallyOpen) _open = true; // the trains just disappeared
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = widget.messages.length;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(n == 1 ? '1 service alert' : '$n service alerts',
                    style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
              ),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: scheme.onSecondaryContainer),
            ]),
          ),
        ),
        if (_open)
          for (final m in widget.messages)
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
              child: Text(m, style: TextStyle(color: scheme.onSecondaryContainer)),
            ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.onRetry});
  final String text;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.info_outline, size: 18, color: scheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
        if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]),
    );
  }
}

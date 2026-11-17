import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../config.dart';
import '../data/departures.dart';
import '../follow/follow_logic.dart';
import '../follow/follower.dart';
import 'departure_row.dart';
import 'format.dart';
import 'station_picker.dart';

/// Beyond this, the nearest station is probably not useful; say so.
const farFromStationMeters = 25000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.openUrl = _launchExternal, this.follower});
  final AppController controller;

  /// Null where trains cannot be followed (iOS for now): rows are then not tappable.
  final Follower? follower;

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

  Widget _row(BuildContext context, Board b, Departure d) => _rowFor(context, widget.follower, b, d);

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

Widget _rowFor(BuildContext context, Follower? follower, Board b, Departure d) {
  if (follower == null) return DepartureRow(d);
  final t = FollowedTrain(crs: b.crs, std: d.std, destination: d.destination);
  final followed = follower.current == t;
  return DepartureRow(d, followed: followed, onTap: () => _toggleFollow(context, follower, t, followed));
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
  if (!await follower.follow(t)) {
    messenger.showSnackBar(const SnackBar(content: Text('Allow notifications to follow a train')));
    return;
  }
  messenger.showSnackBar(SnackBar(
    content: Text('Following ${t.title}'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () => previous == null ? follower.stop() : follower.follow(previous),
    ),
  ));
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

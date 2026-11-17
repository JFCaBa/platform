import 'package:material_ui/material_ui.dart';

import '../data/stations.dart';
import '../domain/nearest.dart';
import 'format.dart';

/// Returned by [pickStation] when the user wants the nearest station again.
const useLocationChoice = '__location__';

/// Bottom sheet with a search field. Empty query: nearest stations first (when the
/// position is known). Returns a CRS, [useLocationChoice] or null.
Future<String?> pickStation(BuildContext context, StationIndex index, (double, double)? coords) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // keep the results above the keyboard
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: _Picker(index: index, coords: coords),
      ),
    );

class _Picker extends StatefulWidget {
  const _Picker({required this.index, required this.coords});
  final StationIndex index;
  final (double, double)? coords;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _query = '';
  List<Station> _results = const [];
  late final List<Station> _nearby = _nearest();

  List<Station> _nearest() {
    final c = widget.coords;
    if (c == null) return const [];
    final list = [...widget.index.stations]
      ..sort((a, b) => haversineMeters(c.$1, c.$2, a.lat, a.lon).compareTo(haversineMeters(c.$1, c.$2, b.lat, b.lon)));
    return list.take(20).toList();
  }

  double? _dist(Station s) {
    final c = widget.coords;
    return c == null ? null : haversineMeters(c.$1, c.$2, s.lat, s.lon);
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().isEmpty ? _nearby : _results;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (ctx, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Station name or code',
              border: OutlineInputBorder(),
            ),
            onChanged: (q) => setState(() {
              _query = q;
              _results = widget.index.search(q);
            }),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: results.length + 1,
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return ListTile(
                  leading: const Icon(Icons.my_location),
                  title: const Text('Use my location'),
                  onTap: () => Navigator.pop(ctx, useLocationChoice),
                );
              }
              final s = results[i - 1];
              final d = _dist(s);
              return ListTile(
                title: Text(s.name),
                subtitle: Text(s.crs),
                trailing: d == null ? null : Text(formatDistance(d)),
                onTap: () => Navigator.pop(ctx, s.crs),
              );
            },
          ),
        ),
      ]),
    );
  }
}

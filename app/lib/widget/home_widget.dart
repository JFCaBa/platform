import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../data/departures.dart';
import '../data/stations.dart';

/// App Group shared with the iOS widget extension.
const widgetAppGroup = 'group.com.jfcaba.platform';
const widgetDataKey = 'next_trains';
const iosWidgetKind = 'NextTrainsWidget';
const androidWidgetProvider = 'NextTrainsWidgetProvider';

/// Services handed to the widget: enough for a couple of hours if its own fetches fail.
const widgetServices = 40;

/// What the home screen widget needs: the station (it fetches that board itself), the filters it
/// applies, and the app's latest board, used until the widget's own is newer.
Map<String, Object?> widgetSnapshot(Station station, Set<String> filters, Board? board, List<Departure> services) => {
      'crs': station.crs,
      'name': board?.name ?? station.name,
      'filters': filters.toList()..sort(),
      'board': board == null
          ? null
          : {
              'generatedAt': board.generatedAt.millisecondsSinceEpoch ~/ 1000,
              'services': [
                for (final d in services.take(widgetServices))
                  {
                    'std': d.std,
                    'etd': d.etd,
                    'platform': d.platform,
                    'destination': d.destination,
                    'cancelled': d.cancelled,
                  },
              ],
            },
    };

/// Writes the widget's data when it changes and asks the widgets to redraw.
class WidgetPublisher {
  WidgetPublisher({Future<void> Function(String json)? write}) : _write = write ?? _homeWidgetWrite;

  final Future<void> Function(String json) _write;
  String? _last;

  static Future<void> _homeWidgetWrite(String json) async {
    await HomeWidget.saveWidgetData<String>(widgetDataKey, json);
    await HomeWidget.updateWidget(iOSName: iosWidgetKind, androidName: androidWidgetProvider);
  }

  Future<void> publish(Station? station, Set<String> filters, Board? board, List<Departure> services) async {
    if (station == null) return;
    final json = jsonEncode(widgetSnapshot(station, filters, board, services));
    if (json == _last) return;
    _last = json;
    try {
      await _write(json);
    } catch (_) {
      _last = null; // try again next time
    }
  }
}

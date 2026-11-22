import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app_controller.dart';
import 'data/departures.dart';
import 'follow/follow_service.dart';
import 'follow/follow_tracker.dart';
import 'follow/follower.dart';
import 'follow/live_activity.dart';
import 'follow/push_follower.dart';
import 'follow/push_token.dart';
import 'location.dart';
import 'ui/home_screen.dart';
import 'widget/home_widget.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  tzdata.initializeTimeZones();
  final client = http.Client();
  final departures = DeparturesClient(client);
  final prefs = await SharedPreferences.getInstance();
  final controller = AppController(
    client,
    await getApplicationSupportDirectory(),
    departures,
    GeolocatorLocationSource(),
    prefs,
  );
  // Android follows in a background service; iOS asks the server to follow and push alerts.
  final Follower? follower = kIsWeb
      ? null
      : Platform.isAndroid
          ? await FollowService.create()
          : Platform.isIOS
              ? await PushFollower.create(
                  client: client, prefs: prefs, push: const ChannelPushToken(), activity: ChannelLiveActivity())
              : null;
  final tracker = follower == null
      ? null
      : FollowTracker(
          follower: follower,
          screen: controller,
          screenBoard: () => controller.board,
          fetchBoard: departures.fetch,
          fetchService: departures.fetchService,
          clock: () => DateTime.now().toUtc(),
        );
  // Home screen widget: station, filters and the latest board (the widget refreshes it itself).
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    if (Platform.isIOS) await HomeWidget.setAppGroupId(widgetAppGroup);
    final publisher = WidgetPublisher();
    controller.addListener(
        () => publisher.publish(controller.station, controller.filters, controller.board, controller.services));
  }
  runApp(PlatformApp(controller: controller, follower: follower, tracker: tracker, fetchStops: departures.fetchStops));
}

class PlatformApp extends StatefulWidget {
  const PlatformApp({super.key, required this.controller, this.follower, this.tracker, this.fetchStops});
  final AppController controller;
  final Follower? follower;
  final FollowTracker? tracker;
  final StopsFetcher? fetchStops;

  @override
  State<PlatformApp> createState() => _PlatformAppState();
}

class _PlatformAppState extends State<PlatformApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.onForeground();
      widget.follower?.sync();
      widget.tracker?.onForeground();
    }
    if (state == AppLifecycleState.paused) {
      widget.controller.onBackground();
      widget.tracker?.onBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1E3A8A);
    return MaterialApp(
      title: 'What Platform',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: HomeScreen(
          controller: widget.controller, follower: widget.follower, tracker: widget.tracker, fetchStops: widget.fetchStops),
    );
  }
}

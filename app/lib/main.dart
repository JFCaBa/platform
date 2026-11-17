import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'app_controller.dart';
import 'data/departures.dart';
import 'follow/follow_service.dart';
import 'follow/follower.dart';
import 'location.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  tzdata.initializeTimeZones();
  final client = http.Client();
  final controller = AppController(
    client,
    await getApplicationSupportDirectory(),
    DeparturesClient(client),
    GeolocatorLocationSource(),
    await SharedPreferences.getInstance(),
  );
  // Following a train needs a background service: Android only for now.
  final follower = !kIsWeb && Platform.isAndroid ? await FollowService.create() : null;
  runApp(PlatformApp(controller: controller, follower: follower));
}

class PlatformApp extends StatefulWidget {
  const PlatformApp({super.key, required this.controller, this.follower});
  final AppController controller;
  final Follower? follower;

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
    }
    if (state == AppLifecycleState.paused) widget.controller.onBackground();
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
      home: HomeScreen(controller: widget.controller, follower: widget.follower),
    );
  }
}

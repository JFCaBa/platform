import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_app/config.dart';

void main() {
  test('User-Agent carries the app version (major.minor from pubspec.yaml)', () {
    final version = RegExp(r'^version:\s*(\d+)\.(\d+)\.', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())!;
    expect(userAgent, 'WhatPlatform/${version[1]}.${version[2]}');
  });

  test('station list comes from our server', () {
    expect(stationsUrl, '$apiBaseUrl/stations.json');
    expect(apiBaseUrl, 'https://api.whatplatform.uk');
  });

  test('privacy policy is /privacy: the root is the website since 25-11-2026', () {
    expect(privacyUrl, 'https://whatplatform.uk/privacy');
  });
}

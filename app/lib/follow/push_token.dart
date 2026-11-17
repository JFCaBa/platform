import 'package:flutter/services.dart';

/// The device's push registration (APNs on iOS).
abstract class PushToken {
  /// Asks to show alerts; false when the user said no.
  Future<bool> requestPermission();

  /// Lowercase hex device token, or null when the device could not register.
  Future<String?> token();

  /// APNs environment the token belongs to: 'sandbox' or 'production'.
  Future<String> environment();

  /// Opens this app's page in the Settings app.
  Future<void> openSettings();
}

/// Talks to AppDelegate.swift over the `whatplatform/push` channel.
class ChannelPushToken implements PushToken {
  const ChannelPushToken();

  static const _channel = MethodChannel('whatplatform/push');

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> token() async {
    try {
      return await _channel.invokeMethod<String>('token');
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String> environment() async {
    try {
      return await _channel.invokeMethod<String>('environment') == 'sandbox' ? 'sandbox' : 'production';
    } on PlatformException {
      return 'production';
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException {
      // nothing to do: the user can still open Settings by hand
    }
  }
}

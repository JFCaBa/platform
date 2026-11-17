import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// APNs device token as lowercase hex, once iOS has given one. Never logged.
  private var deviceToken: String?
  /// Callers waiting for iOS to answer registerForRemoteNotifications.
  private var pendingToken: [FlutterResult] = []
  private var tokenTimeout: DispatchWorkItem?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "whatplatform/push", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "token":
      if let token = deviceToken {
        result(token)
        return
      }
      pendingToken.append(result)
      if pendingToken.count == 1 {
        let timeout = DispatchWorkItem { [weak self] in
          self?.finishToken(FlutterError(code: "timeout", message: "No push token", details: nil))
        }
        tokenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        UIApplication.shared.registerForRemoteNotifications()
      }
    case "environment":
      result(AppDelegate.apsEnvironment())
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finishToken(_ value: Any?) {
    tokenTimeout?.cancel()
    tokenTimeout = nil
    let waiting = pendingToken
    pendingToken = []
    for r in waiting { r(value) }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    self.deviceToken = hex
    finishToken(hex)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    finishToken(FlutterError(code: "register_failed", message: error.localizedDescription, details: nil))
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// "sandbox" for development-signed builds (their provisioning profile says aps-environment
  /// development); App Store and TestFlight builds carry no profile and use "production".
  private static func apsEnvironment() -> String {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url)
    else { return "production" }
    let text = String(decoding: data, as: UTF8.self)
    let pattern = "<key>aps-environment</key>\\s*<string>development</string>"
    return text.range(of: pattern, options: .regularExpression) != nil ? "sandbox" : "production"
  }
}

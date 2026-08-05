import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBackupChannel(with: engineBridge.pluginRegistry)
  }

  /// Serves `excludeFromBackup`, which Dart calls for Tor's data directory.
  ///
  /// Arti keeps its own copy of the onion service key there, along with guard
  /// state. Neither belongs in an iCloud backup that leaves the device, and
  /// `NSURLIsExcludedFromBackupKey` is the only way to say so.
  private func registerBackupChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AgentsAppBackup") else { return }
    let channel = FlutterMethodChannel(
      name: "dev.jamiewest.agentsApp/backup",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(
          FlutterError(code: "bad-arguments", message: "A path is required.", details: nil))
        return
      }
      do {
        var url = URL(fileURLWithPath: path)
        // The flag can only be set on a URL that exists, and Arti creates its
        // tree lazily on first start — so the directory is made here first.
        // An empty directory is fine for Arti to adopt.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(
          FlutterError(
            code: "exclude-failed", message: error.localizedDescription, details: path))
      }
    }
  }
}

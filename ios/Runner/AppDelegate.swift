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
    registerHardwareChannel(with: engineBridge.pluginRegistry)
  }

  /// Serves `cpuUsage` for the Settings > Hardware live monitor.
  ///
  /// The sampler measures between calls, so the Dart side's poll interval
  /// is the measurement window.
  private func registerHardwareChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AgentsAppHardware") else { return }
    let sampler = CpuUsageSampler()
    let channel = FlutterMethodChannel(
      name: "dev.jamiewest.agentsApp/hardware",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "cpuUsage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(sampler.sample())
    }
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

/// Whole-machine CPU usage from Mach per-processor tick counters.
///
/// Twin of the sampler in `macos/Runner/MainFlutterWindow.swift` — the
/// Runner projects predate Xcode's synchronized groups, so a shared file
/// would mean hand-editing both pbxproj files; keep the two in step.
final class CpuUsageSampler {
  private var previousTicks: (busy: UInt64, total: UInt64)?

  /// Usage across all cores since the previous call, 0–1.
  ///
  /// Returns nil on the first call: the counters are totals since boot, so
  /// a single reading has no interval to measure over.
  func sample() -> Double? {
    guard let current = Self.readTicks() else { return nil }
    defer { previousTicks = current }
    guard let previous = previousTicks else { return nil }
    let totalDelta = current.total &- previous.total
    guard totalDelta > 0 else { return nil }
    let busyDelta = current.busy &- previous.busy
    return Double(busyDelta) / Double(totalDelta)
  }

  private static func readTicks() -> (busy: UInt64, total: UInt64)? {
    var processorCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let status = host_processor_info(
      mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
    guard status == KERN_SUCCESS, let ticks = info else { return nil }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: ticks)),
        vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
    }
    var busy: UInt64 = 0
    var total: UInt64 = 0
    for cpu in 0..<Int(processorCount) {
      let base = cpu * Int(CPU_STATE_MAX)
      // The counters are unsigned 32-bit values that wrap; reading them via
      // the bit pattern keeps a wrapped counter from going negative.
      let user = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]))
      let system = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]))
      let nice = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]))
      let idle = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)]))
      busy &+= user &+ system &+ nice
      total &+= user &+ system &+ nice &+ idle
    }
    return (busy, total)
  }
}

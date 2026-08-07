import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerHardwareChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// Serves `cpuUsage` for the Settings > Hardware live monitor.
  ///
  /// The sampler measures between calls, so the Dart side's poll interval is
  /// the measurement window; the messenger retains the handler, so no
  /// property needs to hold the channel.
  private func registerHardwareChannel(messenger: FlutterBinaryMessenger) {
    let sampler = CpuUsageSampler()
    let channel = FlutterMethodChannel(
      name: "dev.jamiewest.agentsApp/hardware",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "cpuUsage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(sampler.sample())
    }
  }
}

/// Whole-machine CPU usage from Mach per-processor tick counters.
///
/// Twin of the sampler in `ios/Runner/AppDelegate.swift` — the Runner
/// projects predate Xcode's synchronized groups, so a shared file would
/// mean hand-editing both pbxproj files; keep the two in step.
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

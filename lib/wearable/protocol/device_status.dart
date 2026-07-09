/// Status JSON model (PROTOCOL.md §2.1).
library;

import 'dart:convert';

/// WiFi radio state reported by the device.
enum DeviceWifiState {
  /// Radio off; BLE-only.
  off,

  /// Attempting to join the provisioned network.
  joining,

  /// Joined; the HTTP endpoint should be published.
  up,

  /// Last join attempt failed.
  failed;

  static DeviceWifiState _parse(Object? value) => switch (value) {
    'off' => DeviceWifiState.off,
    'joining' => DeviceWifiState.joining,
    'up' => DeviceWifiState.up,
    'failed' => DeviceWifiState.failed,
    _ => DeviceWifiState.off,
  };
}

/// A decoded Status notification/read from the device.
class DeviceStatus {
  /// Creates a [DeviceStatus].
  const DeviceStatus({
    required this.firmwareVersion,
    required this.epochMs,
    required this.recording,
    required this.batteryPercent,
    required this.charging,
    required this.bufferedBytes,
    required this.fileCount,
    required this.wifi,
    required this.checkinRequested,
  });

  /// Decodes the UTF-8 JSON payload of a Status characteristic value.
  factory DeviceStatus.fromBytes(List<int> bytes) => DeviceStatus.fromJson(
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
  );

  /// Decodes a Status JSON object (also returned by `GET /status`).
  factory DeviceStatus.fromJson(Map<String, Object?> json) => DeviceStatus(
    firmwareVersion: json['fw'] as String? ?? 'unknown',
    epochMs: (json['epoch_ms'] as num?)?.toInt() ?? 0,
    recording: json['recording'] as bool? ?? false,
    batteryPercent: (json['battery_pct'] as num?)?.toInt() ?? 0,
    charging: json['charging'] as bool? ?? false,
    bufferedBytes: (json['buffered_bytes'] as num?)?.toInt() ?? 0,
    fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
    wifi: DeviceWifiState._parse(json['wifi']),
    checkinRequested: json['checkin'] as bool? ?? false,
  );

  /// Firmware version string, e.g. `0.1.0`.
  final String firmwareVersion;

  /// Device wall-clock in Unix ms; `0` when never time-synced.
  final int epochMs;

  /// Whether continuous audio capture is active.
  final bool recording;

  /// Battery level 0–100.
  final int batteryPercent;

  /// Whether a charger is attached.
  final bool charging;

  /// Bytes of un-offloaded captures buffered on SD.
  final int bufferedBytes;

  /// Number of un-offloaded files on SD.
  final int fileCount;

  /// WiFi radio state.
  final DeviceWifiState wifi;

  /// True when the buffer threshold was crossed and the device wants a sync.
  final bool checkinRequested;

  /// Whether the device has ever been time-synced.
  bool get isTimeSynced => epochMs != 0;
}

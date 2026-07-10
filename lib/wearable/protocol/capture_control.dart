/// Control command builders and response parsing (PROTOCOL.md §2.2–§2.3).
library;

import 'dart:convert';

/// Builds the UTF-8 JSON payloads written to the Control characteristic.
///
/// Each builder returns bytes ready for a single GATT write; commands must
/// fit in one MTU (§2), which these all comfortably do.
abstract final class CaptureCommands {
  static List<int> _encode(Map<String, Object?> json) =>
      utf8.encode(jsonEncode(json));

  /// `time_sync` — establish the device's wall-clock offset.
  static List<int> timeSync(int epochMs) =>
      _encode({'op': 'time_sync', 'epoch_ms': epochMs});

  /// `capture_image` — take a JPEG still immediately.
  static List<int> captureImage() => _encode({'op': 'capture_image'});

  /// `record` — start or stop continuous audio capture.
  static List<int> record({required bool enabled}) =>
      _encode({'op': 'record', 'enabled': enabled});

  /// `set_policy` — persist capture policy values; omitted args unchanged.
  ///
  /// [silenceRms] is the silence-gate threshold (PROTOCOL.md §4): segments
  /// whose RMS never exceeds it are discarded on-device. 0 disables the gate.
  static List<int> setPolicy({
    int? imageIntervalSeconds,
    int? segmentSeconds,
    int? checkinThresholdBytes,
    int? silenceRms,
  }) => _encode({
    'op': 'set_policy',
    'image_interval_s': ?imageIntervalSeconds,
    'segment_s': ?segmentSeconds,
    'checkin_threshold_bytes': ?checkinThresholdBytes,
    'silence_rms': ?silenceRms,
  });

  /// `wipe_captures` — delete every capture on the device's SD card,
  /// including un-synced data (§2.2, v0.4). Destructive; confirm with the
  /// user before sending.
  static List<int> wipeCaptures() => _encode({'op': 'wipe_captures'});

  /// `wifi_join` — bring up WiFi + HTTP server and publish the endpoint.
  static List<int> wifiJoin() => _encode({'op': 'wifi_join'});

  /// `wifi_leave` — drop WiFi and stop the HTTP server.
  static List<int> wifiLeave() => _encode({'op': 'wifi_leave'});

  /// `flush_ble` — begin (or resume) the BLE fallback transfer (§6).
  static List<int> flushBle({int? resumeId, int? resumeOffset}) => _encode({
    'op': 'flush_ble',
    'resume_id': ?resumeId,
    'resume_offset': ?resumeOffset,
  });

  /// WiFi Provision characteristic payload (not a Control op; §2).
  static List<int> wifiProvision({required String ssid, required String psk}) =>
      _encode({'ssid': ssid, 'psk': psk});
}

/// Error codes a command can fail with (§2.3).
enum CaptureControlError {
  /// The write was not a valid JSON object.
  badJson('bad_json'),

  /// Unrecognized `op`.
  unknownOp('unknown_op'),

  /// The device is busy with a conflicting operation.
  busy('busy'),

  /// `wifi_join` without provisioned credentials.
  noWifiCreds('no_wifi_creds'),

  /// The provisioned network rejected the join.
  wifiAuthFailed('wifi_auth_failed'),

  /// SD card failure.
  sdError('sd_error'),

  /// Camera failure.
  cameraError('camera_error'),

  /// An error code this client version does not know.
  unknown('unknown');

  const CaptureControlError(this.wireValue);

  /// The string carried in the response `err` field.
  final String wireValue;

  static CaptureControlError _parse(String value) =>
      CaptureControlError.values.firstWhere(
        (e) => e.wireValue == value,
        orElse: () => CaptureControlError.unknown,
      );
}

/// A decoded Control Response notification (§2.3).
class ControlResponse {
  /// Creates a [ControlResponse].
  const ControlResponse({
    required this.op,
    required this.ok,
    this.error,
    this.captureId,
  });

  /// Decodes the UTF-8 JSON payload of a Control Response notification.
  factory ControlResponse.fromBytes(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final err = json['err'] as String?;
    return ControlResponse(
      op: json['op'] as String? ?? '',
      ok: json['ok'] as bool? ?? false,
      error: err == null ? null : CaptureControlError._parse(err),
      captureId: (json['id'] as num?)?.toInt(),
    );
  }

  /// The `op` this responds to.
  final String op;

  /// Whether the command succeeded.
  final bool ok;

  /// Failure reason when [ok] is false.
  final CaptureControlError? error;

  /// For `capture_image`: the manifest id of the new capture.
  final int? captureId;
}

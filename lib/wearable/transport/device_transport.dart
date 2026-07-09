/// Transport interface for the capture device's BLE control plane.
///
/// The pipeline and UI depend on this interface, never on flutter_blue_plus
/// directly, so they are testable against a fake (see
/// `test/wearable/support/fake_device_transport.dart`).
library;

import 'dart:async';

import '../protocol/protocol.dart';

/// Connection lifecycle of the BLE link.
enum DeviceConnectionState {
  /// Not connected; no scan in progress.
  disconnected,

  /// Scanning for the capture service.
  scanning,

  /// Connecting / discovering services.
  connecting,

  /// Connected with characteristics resolved.
  connected,
}

/// Thrown when a control command gets no response in time (device out of
/// range or busy) — callers surface this as `device_unreachable`.
class DeviceUnreachableException implements Exception {
  /// Creates a [DeviceUnreachableException].
  const DeviceUnreachableException(this.message);

  /// Human-readable context.
  final String message;

  @override
  String toString() => 'DeviceUnreachableException: $message';
}

/// BLE control-plane transport (PROTOCOL.md §2).
abstract interface class DeviceTransport {
  /// Connection lifecycle events, including the current state on listen.
  Stream<DeviceConnectionState> get connectionStates;

  /// Decoded Status notifications (§2.1).
  Stream<DeviceStatus> get statusUpdates;

  /// Decoded Endpoint notifications; `null` while WiFi is down (§2.4).
  Stream<DeviceEndpoint?> get endpointUpdates;

  /// The current connection state.
  DeviceConnectionState get connectionState;

  /// Scans for a capture device, connects, and resolves characteristics.
  Future<void> connect({Duration timeout});

  /// Tears down the connection.
  Future<void> disconnect();

  /// Writes a control command and awaits its response notification (§2.3).
  ///
  /// Commands are serialized: one in flight at a time. Throws
  /// [DeviceUnreachableException] on timeout or when disconnected.
  Future<ControlResponse> sendCommand(
    List<int> payload, {
    Duration timeout = const Duration(seconds: 10),
  });

  /// Writes WiFi credentials to the provisioning characteristic (§2).
  Future<void> provisionWifi({required String ssid, required String psk});

  /// Reads the current Status value on demand.
  Future<DeviceStatus> readStatus();

  /// Reads the current Endpoint value; `null` while WiFi is down.
  Future<DeviceEndpoint?> readEndpoint();

  /// Releases resources.
  Future<void> dispose();
}

/// In-memory [DeviceTransport] for pipeline/UI tests: scripted status and
/// endpoint values, canned control responses, recorded writes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/transport/device_transport.dart';

/// Fake transport driven by the test.
class FakeDeviceTransport implements DeviceTransport {
  final _connectionStates = StreamController<DeviceConnectionState>.broadcast();
  final _statusUpdates = StreamController<DeviceStatus>.broadcast();
  final _endpointUpdates = StreamController<DeviceEndpoint?>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  /// Decoded ops written via [sendCommand], in order.
  final List<Map<String, Object?>> sentCommands = [];

  /// Credentials captured by [provisionWifi].
  final List<(String, String)> provisionedCredentials = [];

  /// Maps an op name to its scripted response; ops without an entry get
  /// `{op, ok: true}`.
  final Map<String, ControlResponse> cannedResponses = {};

  /// When true, [connect] and [sendCommand] throw
  /// [DeviceUnreachableException].
  bool unreachable = false;

  /// Value returned by [readStatus].
  DeviceStatus status = DeviceStatus.fromJson(const {'fw': 'fake'});

  /// Value returned by [readEndpoint].
  DeviceEndpoint? endpoint;

  @override
  Stream<DeviceConnectionState> get connectionStates async* {
    yield _state;
    yield* _connectionStates.stream;
  }

  @override
  Stream<DeviceStatus> get statusUpdates => _statusUpdates.stream;

  @override
  Stream<DeviceEndpoint?> get endpointUpdates => _endpointUpdates.stream;

  @override
  DeviceConnectionState get connectionState => _state;

  /// Drives the connection state and stream from the test.
  void setConnectionState(DeviceConnectionState state) {
    _state = state;
    _connectionStates.add(state);
  }

  /// Emits a status notification.
  void emitStatus(DeviceStatus value) => _statusUpdates.add(value);

  /// Emits an endpoint notification.
  void emitEndpoint(DeviceEndpoint? value) => _endpointUpdates.add(value);

  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    if (unreachable) {
      throw const DeviceUnreachableException('fake: unreachable');
    }
    setConnectionState(DeviceConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    setConnectionState(DeviceConnectionState.disconnected);
  }

  @override
  Future<ControlResponse> sendCommand(
    List<int> payload, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (unreachable || _state != DeviceConnectionState.connected) {
      throw const DeviceUnreachableException('fake: unreachable');
    }
    final json = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
    sentCommands.add(json);
    final op = json['op']! as String;
    return cannedResponses[op] ?? ControlResponse(op: op, ok: true);
  }

  @override
  Future<void> provisionWifi({
    required String ssid,
    required String psk,
  }) async {
    provisionedCredentials.add((ssid, psk));
  }

  @override
  Future<DeviceStatus> readStatus() async => status;

  @override
  Future<DeviceEndpoint?> readEndpoint() async => endpoint;

  @override
  Future<void> dispose() async {
    await _connectionStates.close();
    await _statusUpdates.close();
    await _endpointUpdates.close();
  }
}

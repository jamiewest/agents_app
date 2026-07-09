/// flutter_blue_plus implementation of [DeviceTransport] (macOS + iOS).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/protocol.dart';
import 'device_transport.dart';

/// BLE transport over flutter_blue_plus.
class BleDeviceTransport implements DeviceTransport {
  final _connectionStates = StreamController<DeviceConnectionState>.broadcast();
  final _statusUpdates = StreamController<DeviceStatus>.broadcast();
  final _endpointUpdates = StreamController<DeviceEndpoint?>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _status;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _controlResponse;
  BluetoothCharacteristic? _endpoint;
  BluetoothCharacteristic? _wifiProvision;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Serializes control commands: one in flight at a time (§2.3 guarantees
  /// exactly one response per command).
  Future<void> _commandChain = Future<void>.value();

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

  void _setState(DeviceConnectionState state) {
    _state = state;
    _connectionStates.add(state);
  }

  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    if (_state == DeviceConnectionState.connected) return;
    _setState(DeviceConnectionState.scanning);
    try {
      // The adapter reports off/unknown briefly after app launch; scanning
      // before it is on silently finds nothing and times out (seen as
      // "first connect click always fails").
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw const DeviceUnreachableException(
              'bluetooth adapter is not on',
            ),
          );
      final device = await _scanForDevice(timeout);
      _setState(DeviceConnectionState.connecting);
      // Personal/non-commercial use per the flutter_blue_plus v2 license
      // model; revisit if the app is ever distributed commercially.
      await device.connect(timeout: timeout, license: License.nonprofit);
      _device = device;
      _subscriptions.add(
        device.connectionState.listen((s) {
          if (s == BluetoothConnectionState.disconnected &&
              _state == DeviceConnectionState.connected) {
            _teardown();
          }
        }),
      );
      await _resolveCharacteristics(device);
      _setState(DeviceConnectionState.connected);
      developer.log(
        'connected to ${device.advName}',
        name: 'wearable.transport',
      );
    } catch (e) {
      await _teardown();
      throw DeviceUnreachableException('connect failed: $e');
    }
  }

  Future<BluetoothDevice> _scanForDevice(Duration timeout) async {
    final completer = Completer<BluetoothDevice>();
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!completer.isCompleted) {
          completer.complete(r.device);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(captureServiceUuid)],
        timeout: timeout,
      );
      return await completer.future.timeout(
        timeout,
        onTimeout: () =>
            throw const DeviceUnreachableException('no device found in scan'),
      );
    } finally {
      await subscription.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _resolveCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid == Guid(captureServiceUuid),
      orElse: () =>
          throw const DeviceUnreachableException('capture service missing'),
    );
    BluetoothCharacteristic byUuid(String uuid) =>
        service.characteristics.firstWhere(
          (c) => c.uuid == Guid(uuid),
          orElse: () =>
              throw DeviceUnreachableException('characteristic $uuid missing'),
        );

    _status = byUuid(statusCharacteristicUuid);
    _control = byUuid(controlCharacteristicUuid);
    _controlResponse = byUuid(controlResponseCharacteristicUuid);
    _endpoint = byUuid(endpointCharacteristicUuid);
    _wifiProvision = byUuid(wifiProvisionCharacteristicUuid);

    await _status!.setNotifyValue(true);
    _subscriptions.add(
      _status!.onValueReceived.listen((value) {
        try {
          _statusUpdates.add(DeviceStatus.fromBytes(value));
        } catch (e) {
          developer.log('bad status payload: $e', name: 'wearable.transport');
        }
      }),
    );
    await _endpoint!.setNotifyValue(true);
    _subscriptions.add(
      _endpoint!.onValueReceived.listen((value) {
        try {
          _endpointUpdates.add(DeviceEndpoint.fromBytes(value));
        } catch (e) {
          developer.log('bad endpoint payload: $e', name: 'wearable.transport');
        }
      }),
    );
    await _controlResponse!.setNotifyValue(true);
  }

  Future<void> _teardown() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    final device = _device;
    _device = null;
    _status = null;
    _control = null;
    _controlResponse = null;
    _endpoint = null;
    _wifiProvision = null;
    if (device != null && device.isConnected) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> disconnect() => _teardown();

  @override
  Future<ControlResponse> sendCommand(
    List<int> payload, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final result = _commandChain.then((_) => _sendCommandNow(payload, timeout));
    // Keep the chain alive whether or not this command fails.
    _commandChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ControlResponse> _sendCommandNow(
    List<int> payload,
    Duration timeout,
  ) async {
    final control = _control;
    final response = _controlResponse;
    if (control == null || response == null) {
      throw const DeviceUnreachableException('not connected');
    }
    final expectedOp =
        (jsonDecode(utf8.decode(payload)) as Map<String, Object?>)['op']
            as String?;
    final completer = Completer<ControlResponse>();
    final subscription = response.onValueReceived.listen((value) {
      try {
        final decoded = ControlResponse.fromBytes(value);
        if (!completer.isCompleted && decoded.op == expectedOp) {
          completer.complete(decoded);
        }
      } catch (_) {}
    });
    try {
      await control.write(payload);
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw DeviceUnreachableException(
          'no response to $expectedOp within ${timeout.inSeconds}s',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> provisionWifi({
    required String ssid,
    required String psk,
  }) async {
    final characteristic = _wifiProvision;
    if (characteristic == null) {
      throw const DeviceUnreachableException('not connected');
    }
    await characteristic.write(
      CaptureCommands.wifiProvision(ssid: ssid, psk: psk),
    );
  }

  @override
  Future<DeviceStatus> readStatus() async {
    final characteristic = _status;
    if (characteristic == null) {
      throw const DeviceUnreachableException('not connected');
    }
    return DeviceStatus.fromBytes(await characteristic.read());
  }

  @override
  Future<DeviceEndpoint?> readEndpoint() async {
    final characteristic = _endpoint;
    if (characteristic == null) {
      throw const DeviceUnreachableException('not connected');
    }
    return DeviceEndpoint.fromBytes(await characteristic.read());
  }

  @override
  Future<void> dispose() async {
    await _teardown();
    await _connectionStates.close();
    await _statusUpdates.close();
    await _endpointUpdates.close();
  }
}

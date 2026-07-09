import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../wearable/protocol/protocol.dart';
import '../../wearable/transport/ble_device_transport.dart';
import '../../wearable/transport/capture_http_client.dart';
import '../../wearable/transport/device_transport.dart';

/// Bring-up screen for the wearable capture device: connect over BLE,
/// provision WiFi, drive control commands, and pull buffered captures.
///
/// This is the phase-1 manual surface; the background pipeline and agent
/// tools replace most of it later.
class WearableScreen extends StatefulWidget {
  /// Creates a [WearableScreen].
  const WearableScreen({super.key});

  @override
  State<WearableScreen> createState() => _WearableScreenState();
}

class _WearableScreenState extends State<WearableScreen> {
  final DeviceTransport _transport = BleDeviceTransport();
  final _ssidController = TextEditingController();
  final _pskController = TextEditingController();
  final List<String> _log = [];

  DeviceConnectionState _connection = DeviceConnectionState.disconnected;
  DeviceStatus? _status;
  DeviceEndpoint? _endpoint;
  bool _busy = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      _transport.connectionStates.listen(
        (s) => setState(() => _connection = s),
      ),
    );
    _subscriptions.add(
      _transport.statusUpdates.listen((s) => setState(() => _status = s)),
    );
    _subscriptions.add(
      _transport.endpointUpdates.listen((e) => setState(() => _endpoint = e)),
    );
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _ssidController.dispose();
    _pskController.dispose();
    unawaited(_transport.dispose());
    super.dispose();
  }

  void _logLine(String message) {
    developer.log(message, name: 'wearable.ui');
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $message');
    });
  }

  Future<void> _guard(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _logLine('$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _guard('connect', () async {
    _logLine('scanning…');
    await _transport.connect();
    _logLine('connected');
    setState(() {});
    _status = await _transport.readStatus();
    _endpoint = await _transport.readEndpoint();
    setState(() {});
  });

  Future<void> _timeSync() => _guard('time_sync', () async {
    final response = await _transport.sendCommand(
      CaptureCommands.timeSync(DateTime.now().millisecondsSinceEpoch),
    );
    _logLine(response.ok ? 'time synced' : 'time sync: ${response.error}');
  });

  Future<void> _captureImage() => _guard('capture_image', () async {
    final response = await _transport.sendCommand(
      CaptureCommands.captureImage(),
    );
    _logLine(
      response.ok
          ? 'captured image id ${response.captureId}'
          : 'capture failed: ${response.error?.wireValue}',
    );
  });

  Future<void> _setRecording(bool enabled) => _guard('record', () async {
    await _transport.sendCommand(CaptureCommands.record(enabled: enabled));
    _logLine('recording ${enabled ? 'enabled' : 'disabled'}');
    _status = await _transport.readStatus();
    setState(() {});
  });

  Future<void> _provision() => _guard('provision', () async {
    await _transport.provisionWifi(
      ssid: _ssidController.text,
      psk: _pskController.text,
    );
    _pskController.clear();
    _logLine('wifi credentials provisioned');
  });

  Future<DeviceEndpoint> _ensureEndpoint() async {
    final existing = _endpoint;
    if (existing != null) return existing;
    _logLine('joining wifi…');
    final response = await _transport.sendCommand(
      CaptureCommands.wifiJoin(),
      timeout: const Duration(seconds: 25),
    );
    if (!response.ok) {
      throw StateError('wifi_join failed: ${response.error?.wireValue}');
    }
    final endpoint = await _transport.readEndpoint();
    if (endpoint == null) {
      throw StateError('device joined but published no endpoint');
    }
    setState(() => _endpoint = endpoint);
    return endpoint;
  }

  Future<void> _sync() => _guard('sync', () async {
    final endpoint = await _ensureEndpoint();
    _logLine('endpoint ${endpoint.ip}:${endpoint.port}');
    final client = CaptureHttpClient(endpoint);
    try {
      final manifest = await client.fetchManifest();
      _logLine('${manifest.entries.length} files on device');
      if (manifest.entries.isEmpty) return;

      final dir = await _capturesDirectory();
      final downloaded = <int>[];
      for (final entry in manifest.entries) {
        final name = '${entry.id}_${entry.startEpochMs}.${entry.kind.name}';
        final bytes = await client.download(entry);
        await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
        downloaded.add(entry.id);
        _logLine(
          'saved $name (${(entry.size / 1024).toStringAsFixed(0)} KB, '
          'crc ok)',
        );
      }
      final ack = await client.ack(downloaded);
      _logLine(
        'acked ${downloaded.length} files, device freed '
        '${(ack.freedBytes / 1024).toStringAsFixed(0)} KB',
      );
    } finally {
      client.close();
    }
  });

  Future<Directory> _capturesDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      p.join(support.path, 'wearable', 'captures'),
    ).create(recursive: true);
  }

  Future<void> _openCapturesFolder() async {
    final dir = await _capturesDirectory();
    await launchUrl(Uri.file(dir.path));
  }

  bool get _connected => _connection == DeviceConnectionState.connected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wearable device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ConnectionCard(
            connection: _connection,
            busy: _busy,
            onConnect: _connect,
            onDisconnect: () => _guard('disconnect', _transport.disconnect),
          ),
          if (_connected) ...[
            const SizedBox(height: 12),
            _StatusCard(
              status: _status,
              busy: _busy,
              onTimeSync: _timeSync,
              onCaptureImage: _captureImage,
              onRecordChanged: _setRecording,
            ),
            const SizedBox(height: 12),
            _WifiCard(
              ssidController: _ssidController,
              pskController: _pskController,
              endpoint: _endpoint,
              busy: _busy,
              onProvision: _provision,
              onSync: _sync,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Symbols.folder_open),
                label: const Text('Open captures folder'),
                onPressed: _openCapturesFolder,
              ),
            ],
          ),
          const Divider(),
          for (final line in _log.take(50))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.connection,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
  });

  final DeviceConnectionState connection;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = connection == DeviceConnectionState.connected;
    return Card(
      child: ListTile(
        leading: Icon(
          connected ? Symbols.bluetooth_connected : Symbols.bluetooth,
        ),
        title: Text('Connection: ${connection.name}'),
        trailing: FilledButton(
          onPressed: busy ? null : (connected ? onDisconnect : onConnect),
          child: Text(connected ? 'Disconnect' : 'Connect'),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.busy,
    required this.onTimeSync,
    required this.onCaptureImage,
    required this.onRecordChanged,
  });

  final DeviceStatus? status;
  final bool busy;
  final VoidCallback onTimeSync;
  final VoidCallback onCaptureImage;
  final ValueChanged<bool> onRecordChanged;

  @override
  Widget build(BuildContext context) {
    final s = status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (s == null)
              const Text('Waiting for status…')
            else ...[
              Text(
                'fw ${s.firmwareVersion} · '
                '${s.fileCount} files · '
                '${(s.bufferedBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
                'buffered · wifi ${s.wifi.name}'
                '${s.isTimeSynced ? '' : ' · CLOCK NOT SYNCED'}',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Recording'),
                  Switch(
                    value: s.recording,
                    onChanged: busy ? null : onRecordChanged,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Symbols.schedule),
                    label: const Text('Sync clock'),
                    onPressed: busy ? null : onTimeSync,
                  ),
                  TextButton.icon(
                    icon: const Icon(Symbols.photo_camera),
                    label: const Text('Capture image'),
                    onPressed: busy ? null : onCaptureImage,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WifiCard extends StatelessWidget {
  const _WifiCard({
    required this.ssidController,
    required this.pskController,
    required this.endpoint,
    required this.busy,
    required this.onProvision,
    required this.onSync,
  });

  final TextEditingController ssidController;
  final TextEditingController pskController;
  final DeviceEndpoint? endpoint;
  final bool busy;
  final VoidCallback onProvision;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'WiFi offload',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ssidController,
                    decoration: const InputDecoration(labelText: 'SSID'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: pskController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onProvision,
                  child: const Text('Provision'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  endpoint == null
                      ? 'Endpoint: none (join happens on sync)'
                      : 'Endpoint: ${endpoint!.ip}:${endpoint!.port}',
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Symbols.sync),
                  label: const Text('Sync files'),
                  onPressed: busy ? null : onSync,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

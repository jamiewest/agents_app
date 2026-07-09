import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../wearable/pipeline/capture_archive.dart';
import '../../wearable/pipeline/capture_processor.dart';
import '../../wearable/pipeline/transcription_engine.dart';
import '../../wearable/protocol/protocol.dart';
import '../../wearable/transport/ble_device_transport.dart';
import '../../wearable/transport/capture_http_client.dart';
import '../../wearable/transport/device_transport.dart';

/// Wearable capture device: one-tap sync (connect → clock sync → WiFi →
/// pull → archive → ack → transcribe), recording consent, manual image
/// capture, and one-time WiFi provisioning.
class WearableScreen extends StatefulWidget {
  /// Creates a [WearableScreen].
  const WearableScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<WearableScreen> createState() => _WearableScreenState();
}

class _WearableScreenState extends State<WearableScreen> {
  final DeviceTransport _transport = BleDeviceTransport();
  late final CaptureArchive _archive = CaptureArchive(
    widget.services.getRequiredService<RecordStore>(),
  );
  late final CaptureProcessor _processor = CaptureProcessor(
    archive: _archive,
    transcription: const AppleSpeechEngine(),
    onProcessed: (capture, text) {
      final preview = text.length > 120 ? '${text.substring(0, 120)}…' : text;
      _logLine(
        'transcript ${capture.id}: ${preview.isEmpty ? "(silence)" : preview}',
      );
    },
    onBatchComplete: (processed) =>
        _logLine('${processed.length} captures processed'),
  );
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

  /// Connects (if needed) and syncs the device clock — every session
  /// starts with a fresh clock so captures are time-addressable.
  Future<void> _ensureConnected() async {
    if (_transport.connectionState != DeviceConnectionState.connected) {
      _logLine('scanning…');
      await _transport.connect();
      _logLine('connected');
    }
    final response = await _transport.sendCommand(
      CaptureCommands.timeSync(DateTime.now().millisecondsSinceEpoch),
    );
    if (!response.ok) {
      _logLine('clock sync failed: ${response.error?.wireValue}');
    }
    _status = await _transport.readStatus();
    _endpoint = await _transport.readEndpoint();
    if (mounted) setState(() {});
  }

  Future<void> _connect() => _guard('connect', _ensureConnected);

  Future<void> _captureImage() => _guard('capture_image', () async {
    await _ensureConnected();
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
    await _ensureConnected();
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

  /// The one-tap flow: connect → clock sync → WiFi up → pull → ack.
  Future<void> _sync() => _guard('sync', () async {
    await _ensureConnected();
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
        final path = p.join(dir.path, name);
        await File(path).writeAsBytes(bytes, flush: true);
        // Durable point: file on disk + archive row. Only then is the
        // capture eligible for ack (device-side deletion).
        await _archive.recordDownloaded(
          deviceId: manifest.deviceId,
          entry: entry,
          filePath: path,
        );
        downloaded.add(entry.id);
        _logLine('saved $name (${(entry.size / 1024).toStringAsFixed(0)} KB)');
      }
      final ack = await client.ack(downloaded);
      _logLine(
        'acked ${downloaded.length} files, device freed '
        '${(ack.freedBytes / 1024).toStringAsFixed(0)} KB',
      );
    } finally {
      client.close();
    }
    _logLine('processing captures…');
    unawaited(_processor.processPending());
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    _connected
                        ? Symbols.bluetooth_connected
                        : Symbols.bluetooth,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_connection.name)),
                  if (!_connected)
                    TextButton(
                      onPressed: _busy ? null : _connect,
                      child: const Text('Connect'),
                    )
                  else
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _guard('disconnect', _transport.disconnect),
                      child: const Text('Disconnect'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Symbols.sync),
                    label: const Text('Sync'),
                    onPressed: _busy ? null : _sync,
                  ),
                ],
              ),
            ),
          ),
          if (_connected && _status != null) ...[
            const SizedBox(height: 12),
            _StatusCard(
              status: _status!,
              busy: _busy,
              onCaptureImage: _captureImage,
              onRecordChanged: _setRecording,
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              leading: const Icon(Symbols.wifi_password),
              title: const Text('WiFi credentials'),
              subtitle: const Text(
                'Stored on the device; only needed when the network changes',
              ),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ssidController,
                        decoration: const InputDecoration(labelText: 'SSID'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _pskController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _busy ? null : _provision,
                      child: const Text('Provision'),
                    ),
                  ],
                ),
              ],
            ),
          ),
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.busy,
    required this.onCaptureImage,
    required this.onRecordChanged,
  });

  final DeviceStatus status;
  final bool busy;
  final VoidCallback onCaptureImage;
  final ValueChanged<bool> onRecordChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'fw ${status.firmwareVersion} · '
              '${status.fileCount} files · '
              '${(status.bufferedBytes / (1024 * 1024)).toStringAsFixed(1)} '
              'MB buffered · wifi ${status.wifi.name}',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Recording'),
                Switch(
                  value: status.recording,
                  onChanged: busy ? null : onRecordChanged,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Symbols.photo_camera),
                  label: const Text('Capture image'),
                  onPressed: busy ? null : onCaptureImage,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

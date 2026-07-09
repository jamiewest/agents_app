/// App-wide wearable device service: owns the BLE transport, the offload
/// pipeline, and the wearable memory store, so the device screen and the
/// agent tools drive one shared connection instead of competing ones.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/system.dart' show Disposable;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pipeline/capture_archive.dart';
import 'pipeline/capture_processor.dart';
import 'pipeline/distillation_service.dart';
import 'pipeline/transcription_engine.dart';
import 'pipeline/wearable_memory.dart';
import 'protocol/protocol.dart';
import 'transport/ble_device_transport.dart';
import 'transport/capture_http_client.dart';
import 'transport/device_transport.dart';

/// Outcome of one [WearableService.syncNow] run.
class WearableSyncResult {
  /// Creates a [WearableSyncResult].
  const WearableSyncResult({
    required this.downloadedFiles,
    required this.freedBytes,
  });

  /// Files pulled off the device this run.
  final int downloadedFiles;

  /// Bytes the device freed after the ack.
  final int freedBytes;
}

/// Shared owner of the wearable device connection and pipeline.
class WearableService implements Disposable {
  /// Creates a [WearableService].
  ///
  /// [transport], [transcription], [distillerRunner], and
  /// [resolveCapturesDirectory] are injectable for tests.
  WearableService({
    required RecordStore records,
    required MemoryScorer scorer,
    required AgentConfigurationStore agents,
    required KeyValueStore settings,
    ConfiguredAgentFactory? factory,
    DistillerRunner? distillerRunner,
    DeviceTransport? transport,
    TranscriptionEngine? transcription,
    Future<Directory> Function()? resolveCapturesDirectory,
  }) : _settings = settings,
       transport = transport ?? BleDeviceTransport(),
       _resolveCapturesDirectory =
           resolveCapturesDirectory ?? _defaultCapturesDirectory {
    archive = CaptureArchive(records);
    memory = WearableMemoryStore(
      RecordStoreVectorStore(records, scorer: scorer),
    );
    _distillation = DistillationService(
      agents: agents,
      settings: settings,
      memory: memory,
      factory: factory,
      runner: distillerRunner,
      onLog: _log,
    );
    _processor = CaptureProcessor(
      archive: archive,
      transcription: transcription ?? const AppleSpeechEngine(),
      onProcessed: (capture, text) {
        final preview = text.length > 120 ? '${text.substring(0, 120)}…' : text;
        _log(
          'transcript ${capture.id}: '
          '${preview.isEmpty ? "(silence)" : preview}',
        );
      },
      onBatchComplete: (processed) {
        _log('${processed.length} captures processed, distilling…');
        unawaited(_distillation.distill(processed));
      },
    );
    _subscriptions.add(
      this.transport.statusUpdates.listen((status) {
        lastStatus = status;
        lastStatusAt = DateTime.now();
      }),
    );
    _subscriptions.add(
      this.transport.endpointUpdates.listen((e) => _endpoint = e),
    );
  }

  /// Settings key: whether agents may use the device tools.
  static const String agentAccessKey = 'wearable.agent_access_enabled';

  /// The BLE control-plane transport (streams are shared with the UI).
  final DeviceTransport transport;

  /// Durable archive of offloaded captures.
  late final CaptureArchive archive;

  /// Time-addressable wearable memory.
  late final WearableMemoryStore memory;

  final KeyValueStore _settings;
  final Future<Directory> Function() _resolveCapturesDirectory;
  late final DistillationService _distillation;
  late final CaptureProcessor _processor;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final _logs = StreamController<String>.broadcast();
  Future<WearableSyncResult>? _syncInFlight;
  DeviceEndpoint? _endpoint;

  /// Most recent device status (notify or read), if any this session.
  DeviceStatus? lastStatus;

  /// When [lastStatus] was received.
  DateTime? lastStatusAt;

  /// Human-readable progress lines (UI log).
  Stream<String> get logs => _logs.stream;

  void _log(String message) {
    developer.log(message, name: 'wearable.service');
    if (!_logs.isClosed) _logs.add(message);
  }

  static Future<Directory> _defaultCapturesDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      p.join(support.path, 'wearable', 'captures'),
    ).create(recursive: true);
  }

  /// The folder downloaded captures are written to.
  Future<Directory> capturesDirectory() => _resolveCapturesDirectory();

  /// Whether agents may use the device tools (user consent, default on;
  /// checked in this service layer per the plan's consent rule).
  Future<bool> agentAccessEnabled() async =>
      await _settings.read(agentAccessKey) != 'false';

  /// Grants or revokes agent access to the device tools.
  Future<void> setAgentAccess({required bool enabled}) =>
      _settings.write(agentAccessKey, enabled ? 'true' : 'false');

  /// Connects (when needed) and syncs the device clock, then refreshes the
  /// cached status and endpoint.
  Future<void> ensureConnected({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (transport.connectionState != DeviceConnectionState.connected) {
      _log('scanning…');
      await transport.connect(timeout: timeout);
      _log('connected');
    }
    final response = await transport.sendCommand(
      CaptureCommands.timeSync(DateTime.now().millisecondsSinceEpoch),
    );
    if (!response.ok) {
      _log('clock sync failed: ${response.error?.wireValue}');
    }
    lastStatus = await transport.readStatus();
    lastStatusAt = DateTime.now();
    _endpoint = await transport.readEndpoint();
  }

  /// Disconnects the BLE link.
  Future<void> disconnect() => transport.disconnect();

  /// Takes a still now; returns its capture id (on the device until the
  /// next sync). Throws [DeviceUnreachableException] when out of range.
  Future<int> captureImage() async {
    await ensureConnected();
    final response = await transport.sendCommand(
      CaptureCommands.captureImage(),
    );
    if (!response.ok || response.captureId == null) {
      throw StateError('capture failed: ${response.error?.wireValue}');
    }
    _log('captured image id ${response.captureId}');
    return response.captureId!;
  }

  /// Starts/stops continuous audio capture on the device.
  Future<void> setRecording({required bool enabled}) async {
    await ensureConnected();
    await transport.sendCommand(CaptureCommands.record(enabled: enabled));
    _log('recording ${enabled ? 'enabled' : 'disabled'}');
    lastStatus = await transport.readStatus();
    lastStatusAt = DateTime.now();
  }

  /// Stores WiFi credentials on the device.
  Future<void> provisionWifi({
    required String ssid,
    required String psk,
  }) async {
    await ensureConnected();
    await transport.provisionWifi(ssid: ssid, psk: psk);
    _log('wifi credentials provisioned');
  }

  Future<DeviceEndpoint> _ensureEndpoint() async {
    final existing = _endpoint;
    if (existing != null) return existing;
    _log('joining wifi…');
    final response = await transport.sendCommand(
      CaptureCommands.wifiJoin(),
      timeout: const Duration(seconds: 25),
    );
    if (!response.ok) {
      throw StateError('wifi_join failed: ${response.error?.wireValue}');
    }
    final endpoint = await transport.readEndpoint();
    if (endpoint == null) {
      throw StateError('device joined but published no endpoint');
    }
    _endpoint = endpoint;
    return endpoint;
  }

  /// The full offload flow: connect → clock sync → WiFi → pull → archive →
  /// ack → (async) transcribe + distill. Concurrent calls share one run.
  Future<WearableSyncResult> syncNow() {
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;
    final run = _syncOnce().whenComplete(() => _syncInFlight = null);
    _syncInFlight = run;
    return run;
  }

  Future<WearableSyncResult> _syncOnce() async {
    await ensureConnected();
    final endpoint = await _ensureEndpoint();
    _log('endpoint ${endpoint.ip}:${endpoint.port}');
    final client = CaptureHttpClient(endpoint);
    try {
      final manifest = await client.fetchManifest();
      _log('${manifest.entries.length} files on device');
      if (manifest.entries.isEmpty) {
        return const WearableSyncResult(downloadedFiles: 0, freedBytes: 0);
      }

      final dir = await capturesDirectory();
      final downloaded = <int>[];
      for (final entry in manifest.entries) {
        final name = '${entry.id}_${entry.startEpochMs}.${entry.kind.name}';
        final bytes = await client.download(entry);
        final path = p.join(dir.path, name);
        await File(path).writeAsBytes(bytes, flush: true);
        // Durable point: file on disk + archive row, before the ack lets
        // the device delete its copy.
        await archive.recordDownloaded(
          deviceId: manifest.deviceId,
          entry: entry,
          filePath: path,
        );
        downloaded.add(entry.id);
        _log('saved $name (${(entry.size / 1024).toStringAsFixed(0)} KB)');
      }
      final ack = await client.ack(downloaded);
      _log(
        'acked ${downloaded.length} files, device freed '
        '${(ack.freedBytes / 1024).toStringAsFixed(0)} KB',
      );
      _log('processing captures…');
      unawaited(_processor.processPending());
      return WearableSyncResult(
        downloadedFiles: downloaded.length,
        freedBytes: ack.freedBytes,
      );
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    unawaited(transport.dispose());
    _logs.close();
  }
}

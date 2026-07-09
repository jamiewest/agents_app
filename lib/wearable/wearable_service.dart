/// App-wide wearable device service: owns the BLE transport, the offload
/// pipeline, and the wearable memory store, so the device screen and the
/// agent tools drive one shared connection instead of competing ones.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/system.dart' show Disposable;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pipeline/agent_transcription_engine.dart';
import 'pipeline/capture_archive.dart';
import 'pipeline/capture_processor.dart';
import 'pipeline/distillation_service.dart';
import 'pipeline/image_describer.dart';
import 'pipeline/silence_gate.dart';
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

/// Thrown when the device is reachable over BLE but a command or transfer
/// fails (as opposed to [DeviceUnreachableException], the radio being gone).
class WearableCommandException implements Exception {
  /// Creates a [WearableCommandException].
  const WearableCommandException(this.message);

  /// What failed.
  final String message;

  @override
  String toString() => 'WearableCommandException: $message';
}

/// Shared owner of the wearable device connection and pipeline.
class WearableService implements Disposable {
  /// Creates a [WearableService].
  ///
  /// [transport], [transcription], [distillerRunner],
  /// [resolveCapturesDirectory], and [httpClientFactory] are injectable for
  /// tests.
  WearableService({
    required RecordStore records,
    required MemoryScorer scorer,
    required AgentConfigurationStore agents,
    required KeyValueStore settings,
    ConfiguredAgentFactory? factory,
    DistillerRunner? distillerRunner,
    DescriberRunner? describerRunner,
    TranscriberRunner? transcriberRunner,
    DeviceTransport? transport,
    TranscriptionEngine? transcription,
    ImageDescriber? imageDescriber,
    Future<Directory> Function()? resolveCapturesDirectory,
    CaptureHttpClient Function(DeviceEndpoint endpoint)? httpClientFactory,
  }) : _settings = settings,
       transport = transport ?? BleDeviceTransport(),
       _httpClientFactory = httpClientFactory ?? CaptureHttpClient.new,
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
      // Silence gate first, then the setting picks Apple Speech or the
      // local multimodal model (audio through the distiller agent).
      transcription:
          transcription ??
          SilenceGatedEngine(
            SettingSwitchedEngine(
              settings: settings,
              apple: const AppleSpeechEngine(),
              local: (factory != null || transcriberRunner != null)
                  ? AgentTranscriptionEngine(
                      agents: agents,
                      settings: settings,
                      factory: factory,
                      runner: transcriberRunner,
                    )
                  : null,
            ),
          ),
      imageDescriber:
          imageDescriber ??
          ((factory != null || describerRunner != null)
              ? AgentImageDescriber(
                  agents: agents,
                  settings: settings,
                  factory: factory,
                  runner: describerRunner,
                )
              : null),
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
        unawaited(retentionSweep());
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
  final CaptureHttpClient Function(DeviceEndpoint endpoint) _httpClientFactory;
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
      throw WearableCommandException(
        'capture failed: ${response.error?.wireValue}',
      );
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
      throw WearableCommandException(
        'wifi_join failed: ${response.error?.wireValue}',
      );
    }
    final endpoint = await transport.readEndpoint();
    if (endpoint == null) {
      throw const WearableCommandException(
        'device joined but published no endpoint',
      );
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
    try {
      return await _pull(await _ensureEndpoint());
    } on Exception catch (e) {
      // The published endpoint can outlive the device's actual WiFi session
      // (silent AP drop keeps the characteristic advertising a dead
      // ip/token). Rebuild the session once and retry.
      if (!_isStaleEndpointError(e)) rethrow;
      _log('bulk transfer failed ($e); rejoining wifi…');
      _endpoint = null;
      await transport.sendCommand(CaptureCommands.wifiLeave());
      return _pull(await _ensureEndpoint());
    }
  }

  static bool _isStaleEndpointError(Exception e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException;

  Future<WearableSyncResult> _pull(DeviceEndpoint endpoint) async {
    _log('endpoint ${endpoint.ip}:${endpoint.port}');
    final client = _httpClientFactory(endpoint);
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

  /// How long processed capture files stay on disk. Transcripts,
  /// descriptions, and memory entries are kept forever; only the raw
  /// WAV/JPEG files are purged.
  static const Duration retentionWindow = Duration(days: 7);

  /// Deletes processed capture files older than [window]; returns how many
  /// files were purged. Archive rows and their text survive.
  Future<int> retentionSweep({Duration window = retentionWindow}) async {
    final cutoff = DateTime.now().subtract(window).millisecondsSinceEpoch;
    final candidates = await archive.purgeCandidates(cutoff);
    var purged = 0;
    for (final capture in candidates) {
      final file = File(capture.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      await archive.markFilePurged(capture.id);
      purged++;
    }
    if (purged > 0) {
      _log('retention: purged $purged processed capture files');
    }
    return purged;
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

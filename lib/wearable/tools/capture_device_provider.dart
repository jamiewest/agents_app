/// Agent tools over the wearable capture device (the plan's spec §8).
///
/// Thin adapters over [WearableService] — no protocol logic here. The two
/// live-radio tools fail fast with `device_unreachable` + last-seen info
/// rather than blocking an agent run on the radio. Recall reads wearable
/// memory only; agents never read the device directly. Access is a user
/// consent toggle checked in the service layer: when off, this provider
/// contributes nothing.
library;

import 'dart:convert';

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

import '../transport/device_transport.dart';
import '../wearable_service.dart';

/// Exposes the wearable device to agents as tools.
final class CaptureDeviceProvider extends AIContextProvider {
  /// Creates a [CaptureDeviceProvider] over [service].
  CaptureDeviceProvider(this._service);

  /// Semantic + time-window recall over wearable memory.
  static const String memorySearchToolName = 'wearable_memory_search';

  /// Cached device status (never touches the radio).
  static const String statusToolName = 'wearable_device_status';

  /// Live capture of a still through the device camera.
  static const String captureImageToolName = 'wearable_capture_image';

  /// Trigger the offload pipeline now.
  static const String forceSyncToolName = 'wearable_force_sync';

  final WearableService _service;

  @override
  Future<AIContext> provideAIContext(
    InvokingContext context, {
    CancellationToken? cancellationToken,
  }) async {
    if (!await _service.agentAccessEnabled()) return AIContext();
    // Stable text only — status values here would bust the prompt-prefix
    // cache every turn; live state comes from the tools.
    return AIContext()
      ..instructions =
          'Wearable device context:\n'
          '- The user wears a capture device (microphone + camera): your '
          'eyes and ears on their day. Its observations are transcribed, '
          'summarized, and stored in wearable memory with time ranges.\n'
          '- Use $memorySearchToolName to recall what the wearer heard or '
          'saw (semantic query, optional time window).\n'
          '- Use $statusToolName for battery/buffer/recording state; it '
          'reads a cached value and never waits on the radio.\n'
          '- Use $captureImageToolName to take a photo right now, and '
          '$forceSyncToolName to pull buffered captures off the device; '
          'both need the device in Bluetooth range and may report '
          'device_unreachable.'
      ..tools = [
        _memorySearchTool(),
        _statusTool(),
        _captureImageTool(),
        _forceSyncTool(),
      ];
  }

  AIFunction _memorySearchTool() => AIFunctionFactory.create(
    name: memorySearchToolName,
    description:
        'Search what the wearable device heard and saw. Semantic search '
        'over distilled notes and transcripts, optionally restricted to a '
        'time window.',
    parametersSchema: const {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'What to look for (topic, name, phrase).',
        },
        'from': {
          'type': 'string',
          'description':
              'Optional ISO-8601 local date-time lower bound, e.g. '
              '2026-07-09T09:00.',
        },
        'to': {
          'type': 'string',
          'description': 'Optional ISO-8601 local date-time upper bound.',
        },
        'top': {
          'type': 'integer',
          'description': 'Maximum results (default 5).',
        },
      },
      'required': ['query'],
    },
    callback: (arguments, {cancellationToken}) async {
      final query = (arguments['query'] ?? '').toString();
      final from = _parseEpochMs(arguments['from']);
      final to = _parseEpochMs(arguments['to']);
      final top = (arguments['top'] as num?)?.toInt() ?? 5;
      final entries = await _service.memory.search(
        query,
        top: top,
        fromEpochMs: from,
        toEpochMs: to,
      );
      if (entries.isEmpty) {
        return 'No wearable memories matched. The device may not have '
            'synced recently — consider $forceSyncToolName.';
      }
      return jsonEncode([
        for (final entry in entries)
          {
            'from': _formatEpochMs(entry.startEpochMs),
            'to': _formatEpochMs(entry.endEpochMs),
            'source': entry.source,
            'content': entry.content,
          },
      ]);
    },
  );

  AIFunction _statusTool() => AIFunctionFactory.create(
    name: statusToolName,
    description:
        'Last known status of the wearable device (battery, buffered '
        'captures, recording state). Cached — does not contact the device.',
    parametersSchema: const {'type': 'object', 'properties': {}},
    callback: (arguments, {cancellationToken}) async {
      final status = _service.lastStatus;
      if (status == null) {
        return jsonEncode({
          'seen': false,
          'note':
              'The device has not been seen this app session. '
              '$forceSyncToolName will try to reach it.',
        });
      }
      return jsonEncode({
        'seen': true,
        'last_seen': _service.lastStatusAt?.toIso8601String(),
        'connected':
            _service.transport.connectionState ==
            DeviceConnectionState.connected,
        'recording': status.recording,
        'battery_pct': status.batteryPercent,
        'buffered_bytes': status.bufferedBytes,
        'unsynced_files': status.fileCount,
        'wifi': status.wifi.name,
      });
    },
  );

  AIFunction _captureImageTool() => AIFunctionFactory.create(
    name: captureImageToolName,
    description:
        'Take a photo through the wearable camera right now. The image is '
        'stored on the device; run $forceSyncToolName afterwards to bring '
        'it into wearable memory.',
    parametersSchema: const {'type': 'object', 'properties': {}},
    callback: (arguments, {cancellationToken}) async {
      try {
        final id = await _service.captureImage();
        return jsonEncode({
          'ok': true,
          'capture_id': id,
          'note': 'Stored on the device; sync to retrieve it.',
        });
      } on DeviceUnreachableException catch (e) {
        return _unreachable(e);
      } on Exception catch (e) {
        return _failed('capture_failed', e);
      }
    },
  );

  AIFunction _forceSyncTool() => AIFunctionFactory.create(
    name: forceSyncToolName,
    description:
        'Connect to the wearable device and pull its buffered audio/images '
        'now. Transcription and memory distillation continue in the '
        'background after this returns.',
    parametersSchema: const {'type': 'object', 'properties': {}},
    callback: (arguments, {cancellationToken}) async {
      try {
        final result = await _service.syncNow();
        return jsonEncode({
          'ok': true,
          'downloaded_files': result.downloadedFiles,
          'device_freed_bytes': result.freedBytes,
          'note':
              'Transcription and distillation run in the background; '
              'wearable memory updates shortly.',
        });
      } on DeviceUnreachableException catch (e) {
        return _unreachable(e);
      } on Exception catch (e) {
        return _failed('sync_failed', e);
      }
    },
  );

  String _unreachable(DeviceUnreachableException e) => jsonEncode({
    'ok': false,
    'error': 'device_unreachable',
    'detail': e.message,
    'last_seen': _service.lastStatusAt?.toIso8601String(),
  });

  /// Structured failure the model can act on; without this the framework
  /// swallows the exception into a detail-free generic message.
  static String _failed(String error, Exception e) =>
      jsonEncode({'ok': false, 'error': error, 'detail': e.toString()});

  static int? _parseEpochMs(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.millisecondsSinceEpoch;
  }

  static String _formatEpochMs(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs).toIso8601String();
}

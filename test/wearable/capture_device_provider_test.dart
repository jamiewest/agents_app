import 'dart:convert';
import 'dart:io';

import 'package:agents/agents.dart';
import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/tools/capture_device_provider.dart';
import 'package:agents_app/wearable/wearable_service.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_transport.dart';

class _NoopEngine implements TranscriptionEngine {
  @override
  Future<String> transcribe(String path) async => '';
}

final class _TestAgent extends AIAgent {
  @override
  Future<AgentSession> createSessionCore({
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<AgentSession> deserializeSessionCore(
    dynamic serializedState, {
    Object? jsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<AgentResponse> runCore(
    Iterable<ai.ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Stream<AgentResponseUpdate> runCoreStreaming(
    Iterable<ai.ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<dynamic> serializeSessionCore(
    AgentSession session, {
    Object? jsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

InvokingContext invokingContext() =>
    InvokingContext(_TestAgent(), null, null, AIContext());

Future<Object?> invokeTool(
  AIContext context,
  String name, [
  Map<String, Object?> args = const {},
]) {
  final tool = context.tools!.whereType<ai.AIFunction>().singleWhere(
    (t) => t.name == name,
  );
  return tool.invoke(ai.AIFunctionArguments(args));
}

void main() {
  late FakeDeviceTransport transport;
  late InMemoryKeyValueStore settings;
  late WearableService service;
  late CaptureDeviceProvider provider;
  late Directory tempDir;

  setUp(() {
    transport = FakeDeviceTransport();
    settings = InMemoryKeyValueStore();
    tempDir = Directory.systemTemp.createTempSync('wearable_test');
    service = WearableService(
      records: InMemoryRecordStore(),
      scorer: const KeywordOverlapScorer(),
      agents: AgentConfigurationStore(settings),
      settings: settings,
      distillerRunner: (_, _) async => '',
      transport: transport,
      transcription: _NoopEngine(),
      resolveCapturesDirectory: () async => tempDir,
    );
    provider = CaptureDeviceProvider(service);
  });

  tearDown(() {
    service.dispose();
    tempDir.deleteSync(recursive: true);
  });

  test('contributes nothing when agent access is off', () async {
    await service.setAgentAccess(enabled: false);
    final context = await provider.provideAIContext(invokingContext());
    expect(context.tools, isNull);
    expect(context.instructions, isNull);
  });

  test('offers four tools and stable instructions by default', () async {
    final context = await provider.provideAIContext(invokingContext());
    expect(context.instructions, contains('eyes and ears'));
    expect(context.tools, hasLength(4));
    expect(
      [for (final t in context.tools!.whereType<ai.AIFunction>()) t.name],
      containsAll([
        CaptureDeviceProvider.memorySearchToolName,
        CaptureDeviceProvider.statusToolName,
        CaptureDeviceProvider.captureImageToolName,
        CaptureDeviceProvider.forceSyncToolName,
      ]),
    );
  });

  test('memory search tool returns matched entries as JSON', () async {
    await service.memory.append(
      content: 'Met Alex to plan the garden irrigation project.',
      startEpochMs: 1751990400000,
      endEpochMs: 1751994000000,
      source: 'distilled',
    );
    final context = await provider.provideAIContext(invokingContext());
    final result = await invokeTool(
      context,
      CaptureDeviceProvider.memorySearchToolName,
      {'query': 'garden irrigation Alex'},
    );
    final decoded = jsonDecode(result! as String) as List<Object?>;
    final entry = decoded.single! as Map<String, Object?>;
    expect(entry['content'], contains('irrigation'));
    expect(entry['source'], 'distilled');
  });

  test('memory search reports emptiness helpfully', () async {
    final context = await provider.provideAIContext(invokingContext());
    final result = await invokeTool(
      context,
      CaptureDeviceProvider.memorySearchToolName,
      {'query': 'anything'},
    );
    expect(result, contains('No wearable memories matched'));
  });

  test('status tool reports never-seen without touching the radio', () async {
    final context = await provider.provideAIContext(invokingContext());
    final result = await invokeTool(
      context,
      CaptureDeviceProvider.statusToolName,
    );
    final decoded = jsonDecode(result! as String) as Map<String, Object?>;
    expect(decoded['seen'], false);
  });

  test('status tool serves the cached status after a connection', () async {
    transport.status = DeviceStatus.fromJson(const {
      'fw': '0.1.1',
      'recording': true,
      'battery_pct': 88,
      'buffered_bytes': 1234,
      'file_count': 2,
      'wifi': 'off',
    });
    await service.ensureConnected();

    final context = await provider.provideAIContext(invokingContext());
    final result = await invokeTool(
      context,
      CaptureDeviceProvider.statusToolName,
    );
    final decoded = jsonDecode(result! as String) as Map<String, Object?>;
    expect(decoded['seen'], true);
    expect(decoded['recording'], true);
    expect(decoded['unsynced_files'], 2);
  });

  test('capture image tool returns the new capture id', () async {
    transport.cannedResponses['capture_image'] = const ControlResponse(
      op: 'capture_image',
      ok: true,
      captureId: 42,
    );
    final context = await provider.provideAIContext(invokingContext());
    final result = await invokeTool(
      context,
      CaptureDeviceProvider.captureImageToolName,
    );
    final decoded = jsonDecode(result! as String) as Map<String, Object?>;
    expect(decoded['ok'], true);
    expect(decoded['capture_id'], 42);
  });

  test(
    'retention purges old processed files but keeps rows and text',
    () async {
      final file = File('${tempDir.path}/1.wav');
      await file.writeAsBytes([1, 2, 3]);
      await service.archive.recordDownloaded(
        deviceId: 'dev',
        entry: const ManifestEntry(
          id: 1,
          kind: CaptureKind.wav,
          startEpochMs: 1751990400000,
          durationMs: 60000,
          size: 3,
          crc32: 1,
        ),
        filePath: file.path,
      );
      await service.archive.markDone('dev-1', 'kept transcript');
      // The zero-window cutoff must be strictly after the processed stamp.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final purged = await service.retentionSweep(window: Duration.zero);
      expect(purged, 1);
      expect(file.existsSync(), isFalse);
      final rows = await service.archive.watchAll().first;
      expect(rows.single.resultText, 'kept transcript');
      expect(rows.single.hasFile, isFalse);

      // A second sweep finds nothing to purge.
      expect(await service.retentionSweep(window: Duration.zero), 0);
    },
  );

  test(
    'live tools fail fast with device_unreachable when out of range',
    () async {
      transport.unreachable = true;
      final context = await provider.provideAIContext(invokingContext());
      for (final name in [
        CaptureDeviceProvider.captureImageToolName,
        CaptureDeviceProvider.forceSyncToolName,
      ]) {
        final result = await invokeTool(context, name);
        final decoded = jsonDecode(result! as String) as Map<String, Object?>;
        expect(decoded['ok'], false, reason: name);
        expect(decoded['error'], 'device_unreachable', reason: name);
      }
    },
  );
}

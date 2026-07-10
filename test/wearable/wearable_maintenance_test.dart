/// Maintenance surface: camera policy, device wipe, local capture clearing,
/// and wearable-memory clearing.
library;

import 'dart:io';

import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/wearable_service.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_transport.dart';

class _NoopEngine implements TranscriptionEngine {
  @override
  Future<String> transcribe(String path) async => '';
}

void main() {
  late FakeDeviceTransport transport;
  late InMemoryRecordStore records;
  late InMemoryKeyValueStore settings;
  late Directory tempDir;
  late WearableService service;

  setUp(() {
    transport = FakeDeviceTransport();
    records = InMemoryRecordStore();
    settings = InMemoryKeyValueStore();
    tempDir = Directory.systemTemp.createTempSync('wearable_maint_test');
    service = WearableService(
      records: records,
      scorer: const KeywordOverlapScorer(),
      agents: AgentConfigurationStore(settings),
      settings: settings,
      distillerRunner: (_, _) async => '',
      transport: transport,
      transcription: _NoopEngine(),
      resolveCapturesDirectory: () async => tempDir,
    );
  });

  tearDown(() {
    service.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('setImageInterval', () {
    test('sends set_policy and persists the mirror setting', () async {
      await service.setImageInterval(seconds: 300);

      final command = transport.sentCommands.singleWhere(
        (c) => c['op'] == 'set_policy',
      );
      expect(command['image_interval_s'], 300);
      expect(await settings.read(WearableService.imageIntervalKey), '300');
      expect(await service.imageInterval(), 300);
    });

    test('0 turns the camera off', () async {
      await service.setImageInterval(seconds: 0);

      final command = transport.sentCommands.singleWhere(
        (c) => c['op'] == 'set_policy',
      );
      expect(command['image_interval_s'], 0);
      expect(await service.imageInterval(), 0);
    });

    test('rejects out-of-range intervals without touching the device', () {
      expect(
        () => service.setImageInterval(seconds: 5),
        throwsArgumentError,
      );
      expect(transport.sentCommands, isEmpty);
    });
  });

  group('wipeDeviceCaptures', () {
    test('sends wipe_captures', () async {
      await service.wipeDeviceCaptures();
      expect(
        transport.sentCommands.map((c) => c['op']),
        contains('wipe_captures'),
      );
    });

    test('surfaces device failure', () async {
      transport.cannedResponses['wipe_captures'] = const ControlResponse(
        op: 'wipe_captures',
        ok: false,
        error: CaptureControlError.sdError,
      );
      await expectLater(
        service.wipeDeviceCaptures(),
        throwsA(isA<WearableCommandException>()),
      );
    });
  });

  test('clearLocalCaptures deletes files and archive rows', () async {
    final file = File('${tempDir.path}/1_0.wav')
      ..writeAsBytesSync(const [1, 2, 3]);
    await service.archive.recordDownloaded(
      deviceId: 'dev',
      entry: const ManifestEntry(
        id: 1,
        kind: CaptureKind.wav,
        startEpochMs: 1000,
        durationMs: 60000,
        size: 3,
        crc32: 0,
      ),
      filePath: file.path,
    );

    final removed = await service.clearLocalCaptures();

    expect(removed, 1);
    expect(file.existsSync(), isFalse);
    expect(await service.archive.pending(), isEmpty);
  });

  test('clearMemory removes every entry', () async {
    await service.memory.append(
      content: 'saw a red bicycle',
      startEpochMs: 1000,
      endEpochMs: 2000,
      source: 'distilled',
    );
    await service.memory.append(
      content: 'radio discussed the weather',
      startEpochMs: 3000,
      endEpochMs: 4000,
      source: 'transcript',
    );
    expect(await service.memory.all(), hasLength(2));

    final removed = await service.clearMemory();

    expect(removed, 2);
    expect(await service.memory.all(), isEmpty);
  });

  test('memory.all lists newest first and delete removes one', () async {
    final memory = service.memory;
    await memory.append(
      content: 'older',
      startEpochMs: 1000,
      endEpochMs: 2000,
      source: 'distilled',
    );
    await memory.append(
      content: 'newer',
      startEpochMs: 5000,
      endEpochMs: 6000,
      source: 'distilled',
    );

    final all = await memory.all();
    expect([for (final e in all) e.content], ['newer', 'older']);

    await memory.delete(all.first.key);
    final remaining = await memory.all();
    expect([for (final e in remaining) e.content], ['older']);
  });
}

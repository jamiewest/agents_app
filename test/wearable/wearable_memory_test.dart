import 'package:agents_app/wearable/pipeline/capture_archive.dart';
import 'package:agents_app/wearable/pipeline/distillation_service.dart';
import 'package:agents_app/wearable/pipeline/wearable_memory.dart';
import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

const hourMs = 3600000;
const dayStart = 1751990400000;

WearableMemoryStore newStore() {
  var tick = 0;
  return WearableMemoryStore(
    RecordStoreVectorStore(InMemoryRecordStore()),
    now: () => DateTime.fromMillisecondsSinceEpoch(1752000000000 + tick++),
  );
}

/// Builds a done archived capture carrying [text].
Future<ArchivedCapture> processedCapture(
  CaptureArchive archive,
  int id,
  int startEpochMs,
  String text, {
  CaptureKind kind = CaptureKind.wav,
}) async {
  await archive.recordDownloaded(
    deviceId: 'dev',
    entry: ManifestEntry(
      id: id,
      kind: kind,
      startEpochMs: startEpochMs,
      durationMs: kind == CaptureKind.wav ? 60000 : 0,
      size: 1,
      crc32: 1,
    ),
    filePath: '/tmp/$id.${kind.name}',
  );
  await archive.markDone('dev-$id', text);
  final all = await archive.watchAll().first;
  return all.singleWhere((c) => c.id == 'dev-$id');
}

void main() {
  group('WearableMemoryStore', () {
    test('append + semantic search returns the relevant entry', () async {
      final store = newStore();
      await store.append(
        content: 'Discussed the quarterly budget with Sarah at the office.',
        startEpochMs: dayStart,
        endEpochMs: dayStart + hourMs,
        source: 'distilled',
      );
      await store.append(
        content: 'Walked the dog around the park before lunch.',
        startEpochMs: dayStart + 2 * hourMs,
        endEpochMs: dayStart + 3 * hourMs,
        source: 'distilled',
      );

      final results = await store.search('budget meeting Sarah', top: 1);
      expect(results.single.content, contains('quarterly budget'));
      expect(results.single.startEpochMs, dayStart);
    });

    test('time-window search excludes out-of-range entries', () async {
      final store = newStore();
      await store.append(
        content: 'morning standup notes',
        startEpochMs: dayStart,
        endEpochMs: dayStart + hourMs,
        source: 'transcript',
      );
      await store.append(
        content: 'evening standup notes',
        startEpochMs: dayStart + 10 * hourMs,
        endEpochMs: dayStart + 11 * hourMs,
        source: 'transcript',
      );

      final evening = await store.search(
        'standup notes',
        fromEpochMs: dayStart + 9 * hourMs,
      );
      expect(evening, hasLength(1));
      expect(evening.single.content, 'evening standup notes');
    });

    test('inRange lists oldest first', () async {
      final store = newStore();
      await store.append(
        content: 'second',
        startEpochMs: dayStart + hourMs,
        endEpochMs: dayStart + 2 * hourMs,
        source: 'transcript',
      );
      await store.append(
        content: 'first',
        startEpochMs: dayStart,
        endEpochMs: dayStart + hourMs,
        source: 'transcript',
      );

      final entries = await store.inRange(dayStart, dayStart + 2 * hourMs);
      expect([for (final e in entries) e.content], ['first', 'second']);
    });

    test('empty content is not stored', () async {
      final store = newStore();
      await store.append(
        content: '   ',
        startEpochMs: dayStart,
        endEpochMs: dayStart,
        source: 'transcript',
      );
      expect(await store.inRange(0, 1 << 50), isEmpty);
    });
  });

  group('DistillationService', () {
    late CaptureArchive archive;
    late WearableMemoryStore memory;
    late AgentConfigurationStore agents;
    late InMemoryKeyValueStore settings;

    setUp(() {
      archive = CaptureArchive(
        InMemoryRecordStore(),
        now: () => DateTime.fromMillisecondsSinceEpoch(1752000000000),
      );
      memory = newStore();
      settings = InMemoryKeyValueStore();
      agents = AgentConfigurationStore(settings);
    });

    test('stores raw entries when no distiller is configured', () async {
      final captures = [
        await processedCapture(archive, 1, dayStart, 'talked about lunch'),
        await processedCapture(
          archive,
          2,
          dayStart + hourMs,
          'a desk with a laptop',
          kind: CaptureKind.jpg,
        ),
      ];
      final service = DistillationService(
        agents: agents,
        settings: settings,
        memory: memory,
        runner: (_, _) async => fail('runner must not be called'),
      );
      await service.distill(captures);

      final entries = await memory.inRange(0, 1 << 50);
      expect(entries, hasLength(2));
      expect(entries[0].source, 'transcript');
      expect(entries[1].source, 'image');
    });

    test(
      'runs the configured distiller and stores one distilled note',
      () async {
        await agents.saveAgent(
          SavedAgentConfig(id: 'distiller-1', name: 'Distiller', modelId: 'm'),
        );
        await settings.write(
          DistillationService.distillerAgentIdKey,
          'distiller-1',
        );
        final captures = [
          await processedCapture(archive, 1, dayStart, 'hello from the lab'),
          await processedCapture(
            archive,
            2,
            dayStart + hourMs,
            'more lab chatter',
          ),
        ];

        String? seenPrompt;
        final service = DistillationService(
          agents: agents,
          settings: settings,
          memory: memory,
          runner: (config, prompt) async {
            expect(config.id, 'distiller-1');
            seenPrompt = prompt;
            return 'Worked in the lab through the morning.';
          },
        );
        await service.distill(captures);

        expect(seenPrompt, contains('hello from the lab'));
        expect(seenPrompt, contains('more lab chatter'));
        final entries = await memory.inRange(0, 1 << 50);
        expect(entries.single.source, 'distilled');
        expect(
          entries.single.content,
          'Worked in the lab through the morning.',
        );
        expect(entries.single.startEpochMs, dayStart);
        expect(entries.single.endEpochMs, dayStart + hourMs + 60000);
      },
    );

    test('falls back to raw entries when the distiller run fails', () async {
      await agents.saveAgent(
        SavedAgentConfig(id: 'distiller-1', name: 'Distiller', modelId: 'm'),
      );
      await settings.write(
        DistillationService.distillerAgentIdKey,
        'distiller-1',
      );
      final captures = [
        await processedCapture(archive, 1, dayStart, 'important detail'),
      ];
      final service = DistillationService(
        agents: agents,
        settings: settings,
        memory: memory,
        runner: (_, _) async => throw StateError('model exploded'),
      );
      await service.distill(captures);

      final entries = await memory.inRange(0, 1 << 50);
      expect(entries.single.source, 'transcript');
      expect(entries.single.content, 'important detail');
    });

    test('skips captures with empty results and empty batches', () async {
      final service = DistillationService(
        agents: agents,
        settings: settings,
        memory: memory,
        runner: (_, _) async => fail('runner must not be called'),
      );
      await service.distill(const []);
      expect(await memory.inRange(0, 1 << 50), isEmpty);
    });
  });
}

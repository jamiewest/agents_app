import 'package:agents_app/wearable/pipeline/capture_archive.dart';
import 'package:agents_app/wearable/pipeline/capture_processor.dart';
import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTranscriptionEngine implements TranscriptionEngine {
  final Map<String, String> transcripts = {};
  final Set<String> failing = {};
  final List<String> calls = [];

  @override
  Future<String> transcribe(String path) async {
    calls.add(path);
    if (failing.contains(path)) {
      throw StateError('engine crashed on $path');
    }
    return transcripts[path] ?? '';
  }
}

ManifestEntry wavEntry(int id, {int startEpochMs = 1751990400000}) =>
    ManifestEntry(
      id: id,
      kind: CaptureKind.wav,
      startEpochMs: startEpochMs,
      durationMs: 60000,
      size: 1920044,
      crc32: 1234,
    );

void main() {
  late CaptureArchive archive;
  late FakeTranscriptionEngine engine;

  setUp(() {
    archive = CaptureArchive(
      InMemoryRecordStore(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1752000000000),
    );
    engine = FakeTranscriptionEngine();
  });

  group('CaptureArchive', () {
    test('records a download as pending with device timestamps', () async {
      final capture = await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: wavEntry(7),
        filePath: '/tmp/7.wav',
      );
      expect(capture.id, 'aabbcc-7');
      expect(capture.startEpochMs, 1751990400000);
      expect(capture.timestampApproximate, isFalse);
      final pending = await archive.pending();
      expect(pending.single.id, 'aabbcc-7');
    });

    test(
      'stamps epoch-0 captures with receipt time, flagged approximate',
      () async {
        final capture = await archive.recordDownloaded(
          deviceId: 'aabbcc',
          entry: wavEntry(8, startEpochMs: 0),
          filePath: '/tmp/8.wav',
        );
        // Receipt time minus the segment duration approximates capture start.
        expect(capture.startEpochMs, 1752000000000 - 60000);
        expect(capture.timestampApproximate, isTrue);
      },
    );

    test('markDone removes from pending and stores the transcript', () async {
      await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: wavEntry(9),
        filePath: '/tmp/9.wav',
      );
      await archive.markDone('aabbcc-9', 'hello world');
      expect(await archive.pending(), isEmpty);
    });

    test('markFailed keeps pending until maxAttempts', () async {
      await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: wavEntry(10),
        filePath: '/tmp/10.wav',
      );
      for (var i = 1; i < CaptureArchive.maxAttempts; i++) {
        await archive.markFailed('aabbcc-10', 'boom $i');
        expect(await archive.pending(), hasLength(1), reason: 'attempt $i');
      }
      await archive.markFailed('aabbcc-10', 'final boom');
      expect(await archive.pending(), isEmpty);
    });
  });

  group('CaptureProcessor', () {
    test('transcribes pending wavs oldest-first and reports a batch', () async {
      await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: wavEntry(2, startEpochMs: 1751990460000),
        filePath: '/tmp/2.wav',
      );
      await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: wavEntry(1),
        filePath: '/tmp/1.wav',
      );
      engine.transcripts['/tmp/1.wav'] = 'first';
      engine.transcripts['/tmp/2.wav'] = 'second';

      List<ArchivedCapture>? batch;
      final processed = <String>[];
      final processor = CaptureProcessor(
        archive: archive,
        transcription: engine,
        onProcessed: (c, text) => processed.add(text),
        onBatchComplete: (b) => batch = b,
      );
      await processor.processPending();

      expect(engine.calls, ['/tmp/1.wav', '/tmp/2.wav']);
      expect(processed, ['first', 'second']);
      expect(batch, hasLength(2));
      expect(await archive.pending(), isEmpty);
    });

    test(
      'a failing capture is retried on later runs, not fatal to the batch',
      () async {
        await archive.recordDownloaded(
          deviceId: 'aabbcc',
          entry: wavEntry(1),
          filePath: '/tmp/bad.wav',
        );
        await archive.recordDownloaded(
          deviceId: 'aabbcc',
          entry: wavEntry(2, startEpochMs: 1751990460000),
          filePath: '/tmp/good.wav',
        );
        engine.failing.add('/tmp/bad.wav');
        engine.transcripts['/tmp/good.wav'] = 'fine';

        final processor = CaptureProcessor(
          archive: archive,
          transcription: engine,
        );
        await processor.processPending();

        final pending = await archive.pending();
        expect(pending.single.filePath, '/tmp/bad.wav');
        expect(pending.single.attempts, 1);
      },
    );

    test('jpgs are left pending without an image describer', () async {
      await archive.recordDownloaded(
        deviceId: 'aabbcc',
        entry: const ManifestEntry(
          id: 3,
          kind: CaptureKind.jpg,
          startEpochMs: 1751990400000,
          durationMs: 0,
          size: 14000,
          crc32: 5,
        ),
        filePath: '/tmp/3.jpg',
      );
      final processor = CaptureProcessor(
        archive: archive,
        transcription: engine,
      );
      await processor.processPending();
      expect(await archive.pending(), hasLength(1));
      expect(engine.calls, isEmpty);
    });
  });
}

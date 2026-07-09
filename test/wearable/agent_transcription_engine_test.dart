import 'dart:io';

import 'package:agents_app/wearable/pipeline/agent_transcription_engine.dart';
import 'package:agents_app/wearable/pipeline/distillation_service.dart';
import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

class _RecordingEngine implements TranscriptionEngine {
  _RecordingEngine(this.result);
  final String result;
  final List<String> calls = [];

  @override
  Future<String> transcribe(String path) async {
    calls.add(path);
    return result;
  }
}

void main() {
  late InMemoryKeyValueStore settings;
  late AgentConfigurationStore agents;
  late File wavFile;

  const wavBytes = [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00];

  setUp(() async {
    settings = InMemoryKeyValueStore();
    agents = AgentConfigurationStore(settings);
    wavFile = File(
      '${Directory.systemTemp.createTempSync('transcribe').path}/1.wav',
    );
    await wavFile.writeAsBytes(wavBytes);
  });

  tearDown(() => wavFile.parent.deleteSync(recursive: true));

  Future<void> configureDistiller() async {
    await agents.saveAgent(
      SavedAgentConfig(id: 'distiller-1', name: 'D', modelId: 'm'),
    );
    await settings.write(
      DistillationService.distillerAgentIdKey,
      'distiller-1',
    );
  }

  group('AgentTranscriptionEngine', () {
    test(
      'throws TranscriberUnavailableException without a distiller agent',
      () async {
        final engine = AgentTranscriptionEngine(
          agents: agents,
          settings: settings,
          runner: (_, _) async => fail('runner must not be called'),
        );
        expect(
          () => engine.transcribe(wavFile.path),
          throwsA(isA<TranscriberUnavailableException>()),
        );
      },
    );

    test(
      'sends the audio to the distiller agent and returns its text',
      () async {
        await configureDistiller();
        ai.ChatMessage? seen;
        final engine = AgentTranscriptionEngine(
          agents: agents,
          settings: settings,
          runner: (config, message) async {
            seen = message;
            return ' We should order the parts on Friday. ';
          },
        );
        final text = await engine.transcribe(wavFile.path);
        expect(text, 'We should order the parts on Friday.');
        final data = seen!.contents.whereType<ai.DataContent>().single;
        expect(data.mediaType, 'audio/wav');
        expect(data.data, wavBytes);
      },
    );

    test('maps the no-speech sentinel to an empty transcript', () async {
      await configureDistiller();
      final engine = AgentTranscriptionEngine(
        agents: agents,
        settings: settings,
        runner: (_, _) async => 'NO_SPEECH.',
      );
      expect(await engine.transcribe(wavFile.path), isEmpty);
    });

    test('throws when the agent returns no text', () async {
      await configureDistiller();
      final engine = AgentTranscriptionEngine(
        agents: agents,
        settings: settings,
        runner: (_, _) async => '   ',
      );
      expect(() => engine.transcribe(wavFile.path), throwsA(isA<StateError>()));
    });
  });

  group('SettingSwitchedEngine', () {
    late _RecordingEngine apple;
    late _RecordingEngine local;

    setUp(() {
      apple = _RecordingEngine('from apple');
      local = _RecordingEngine('from local');
    });

    SettingSwitchedEngine engine({bool withLocal = true}) =>
        SettingSwitchedEngine(
          settings: settings,
          apple: apple,
          local: withLocal ? local : null,
        );

    test('routes to Apple when pinned', () async {
      await configureDistiller();
      await settings.write(
        SettingSwitchedEngine.engineSettingKey,
        SettingSwitchedEngine.appleEngine,
      );
      expect(await engine().transcribe('/tmp/a.wav'), 'from apple');
      expect(local.calls, isEmpty);
    });

    test('routes to the local model when pinned', () async {
      await settings.write(
        SettingSwitchedEngine.engineSettingKey,
        SettingSwitchedEngine.localEngine,
      );
      expect(await engine().transcribe('/tmp/a.wav'), 'from local');
      expect(apple.calls, isEmpty);
    });

    test('pinned local without a local engine reports unavailable', () async {
      await settings.write(
        SettingSwitchedEngine.engineSettingKey,
        SettingSwitchedEngine.localEngine,
      );
      expect(
        () => engine(withLocal: false).transcribe('/tmp/a.wav'),
        throwsA(isA<TranscriberUnavailableException>()),
      );
    });

    test('auto prefers local once a distiller agent is set', () async {
      await configureDistiller();
      expect(await engine().transcribe('/tmp/a.wav'), 'from local');
      expect(apple.calls, isEmpty);
    });

    test('auto falls back to Apple without a distiller agent', () async {
      expect(await engine().transcribe('/tmp/a.wav'), 'from apple');
      expect(local.calls, isEmpty);
    });

    test('auto falls back to Apple without a local engine', () async {
      await configureDistiller();
      expect(
        await engine(withLocal: false).transcribe('/tmp/a.wav'),
        'from apple',
      );
    });
  });
}

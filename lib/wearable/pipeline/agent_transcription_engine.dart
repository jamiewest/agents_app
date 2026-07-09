/// Transcribes wearable audio through an agent run, so the local
/// multimodal path (Gemma 4 + audio-capable mmproj via `agents_llama`) —
/// or any audio-capable configured model — turns speech into memory text
/// without the platform speech stack.
library;

import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:path/path.dart' as p;

import 'distillation_service.dart';
import 'transcription_engine.dart';

/// Thrown when the local engine is selected but no distiller agent is
/// configured — the processor leaves the capture pending (no retry burned)
/// until one is selected.
class TranscriberUnavailableException implements Exception {
  /// Creates a [TranscriberUnavailableException].
  const TranscriberUnavailableException();
}

/// Runs the transcriber agent over [message]; returns its response text.
typedef TranscriberRunner =
    Future<String> Function(SavedAgentConfig config, ai.ChatMessage message);

/// [TranscriptionEngine] that reuses the wearable distiller agent for
/// speech-to-text.
///
/// One agent powers distillation, image description, and transcription;
/// point the wearable "distiller agent" at an audio-capable multimodal
/// model (e.g. the local Gemma 4 preset, whose mmproj carries the audio
/// encoder) and WAV captures become transcripts. The runtime's mtmd layer
/// decodes the WAV container and windows long clips itself, so the
/// device's ~60 s segments need no client-side splitting. A model without
/// audio support fails the run, and the capture retries within its normal
/// budget.
class AgentTranscriptionEngine implements TranscriptionEngine {
  /// Creates an [AgentTranscriptionEngine].
  ///
  /// [runner] is injectable for tests (making [factory] optional).
  AgentTranscriptionEngine({
    required this._agents,
    required this._settings,
    ConfiguredAgentFactory? factory,
    TranscriberRunner? runner,
  }) : assert(
         runner != null || factory != null,
         'provide a factory or a runner',
       ),
       _runner = runner ?? _agentRunner(factory!);

  final AgentConfigurationStore _agents;
  final KeyValueStore _settings;
  final TranscriberRunner _runner;

  /// The response that means "nothing to transcribe" (maps to an empty
  /// transcript, same as the silence gate's verdict).
  static const String noSpeechSentinel = 'NO_SPEECH';

  static const String _prompt =
      'This audio clip was recorded by a wearable microphone from the '
      'wearer\'s point of view. Transcribe the speech verbatim; multiple '
      'speakers may be present. Respond with the transcript text only — '
      'no commentary or timestamps. If the clip contains no intelligible '
      'speech, respond with exactly $noSpeechSentinel.';

  static TranscriberRunner _agentRunner(ConfiguredAgentFactory factory) =>
      (config, message) async {
        final agent = await factory.createAgent(
          config,
          scope: AgentScope(
            conversationId: 'wearable-transcribe',
            sessionIdResolver: () => 'wearable-transcribe',
            isPrivate: true,
          ),
        );
        final session = await agent.createSession();
        final response = await agent.run(session, null, messages: [message]);
        return response.text;
      };

  @override
  Future<String> transcribe(String path) async {
    final id = await _settings.read(DistillationService.distillerAgentIdKey);
    final config = (id == null || id.isEmpty)
        ? null
        : await _agents.getAgent(id);
    if (config == null) {
      throw const TranscriberUnavailableException();
    }
    final bytes = await File(path).readAsBytes();
    final message = ai.ChatMessage(
      role: ai.ChatRole.user,
      contents: [
        ai.TextContent(_prompt),
        ai.DataContent(bytes, mediaType: 'audio/wav', name: p.basename(path)),
      ],
    );
    final transcript = (await _runner(config, message)).trim();
    if (RegExp('^$noSpeechSentinel\\W*\$').hasMatch(transcript)) {
      return '';
    }
    if (transcript.isEmpty) {
      throw StateError('transcriber returned no text');
    }
    return transcript;
  }
}

/// Routes transcription to Apple Speech or the local model per the
/// `wearable.transcription_engine` setting.
///
/// Unset (auto) prefers [local] whenever a distiller agent is configured —
/// the same agent transcription runs through — and falls back to [apple]
/// otherwise, so a fresh install still transcribes with zero setup.
class SettingSwitchedEngine implements TranscriptionEngine {
  /// Creates a [SettingSwitchedEngine].
  const SettingSwitchedEngine({
    required this._settings,
    required this._apple,
    this._local,
  });

  /// Settings key selecting the engine: [appleEngine], [localEngine], or
  /// unset for auto.
  static const String engineSettingKey = 'wearable.transcription_engine';

  /// Setting value pinning Apple Speech.
  static const String appleEngine = 'apple';

  /// Setting value pinning the local model (distiller agent).
  static const String localEngine = 'local';

  final KeyValueStore _settings;
  final TranscriptionEngine _apple;
  final TranscriptionEngine? _local;

  @override
  Future<String> transcribe(String path) async {
    final selected = await _settings.read(engineSettingKey);
    switch (selected) {
      case appleEngine:
        return _apple.transcribe(path);
      case localEngine:
        final local = _local;
        if (local == null) {
          throw const TranscriberUnavailableException();
        }
        return local.transcribe(path);
      default:
        final local = _local;
        if (local != null && await _distillerConfigured()) {
          return local.transcribe(path);
        }
        return _apple.transcribe(path);
    }
  }

  Future<bool> _distillerConfigured() async {
    final id = await _settings.read(DistillationService.distillerAgentIdKey);
    return id != null && id.isNotEmpty;
  }
}

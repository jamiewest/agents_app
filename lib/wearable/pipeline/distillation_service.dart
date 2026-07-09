/// Turns processed capture batches into wearable memory.
///
/// Distillation is an agent run in the existing framework (the "distiller"
/// is any configured agent, chosen in the wearable settings). Without a
/// configured distiller — or when the run fails — raw transcripts and image
/// descriptions are stored verbatim, so observations are never lost.
library;

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;

import 'capture_archive.dart';
import 'wearable_memory.dart';

/// Runs a distiller agent over [prompt]; returns its response text.
typedef DistillerRunner =
    Future<String> Function(SavedAgentConfig config, String prompt);

/// Distills processed captures into [WearableMemoryStore] entries.
class DistillationService {
  /// Creates a [DistillationService].
  ///
  /// [runner] is injectable for tests (making [factory] optional); the
  /// default builds the configured agent through [ConfiguredAgentFactory]
  /// and runs it in a private scope.
  DistillationService({
    required this._agents,
    required this._settings,
    required this._memory,
    ConfiguredAgentFactory? factory,
    DistillerRunner? runner,
    this.onLog,
  }) : assert(
         runner != null || factory != null,
         'provide a factory or a runner',
       ),
       _runner = runner ?? _agentRunner(factory!);

  /// Settings key holding the distiller's configured-agent id.
  static const String distillerAgentIdKey = 'wearable.distiller_agent_id';

  final AgentConfigurationStore _agents;
  final KeyValueStore _settings;
  final WearableMemoryStore _memory;
  final DistillerRunner _runner;

  /// Progress/outcome messages for the UI log.
  final void Function(String message)? onLog;

  static DistillerRunner _agentRunner(ConfiguredAgentFactory factory) =>
      (config, prompt) async {
        // Private scope: the distillation turn is machinery, not a
        // conversation — no transcript, no chat-memory writes.
        final agent = await factory.createAgent(
          config,
          scope: AgentScope(
            conversationId: 'wearable-distillation',
            sessionIdResolver: () => 'wearable-distillation',
            isPrivate: true,
          ),
        );
        final session = await agent.createSession();
        final response = await agent.run(
          session,
          null,
          messages: [ai.ChatMessage.fromText(ai.ChatRole.user, prompt)],
        );
        return response.text;
      };

  /// Distills [batch] into memory. Never throws: on any failure the raw
  /// texts are stored verbatim instead.
  Future<void> distill(List<ArchivedCapture> batch) async {
    final captures =
        batch.where((c) => (c.resultText ?? '').trim().isNotEmpty).toList()
          ..sort((a, b) => a.startEpochMs.compareTo(b.startEpochMs));
    if (captures.isEmpty) return;

    final config = await _distillerConfig();
    if (config == null) {
      await _storeVerbatim(captures);
      onLog?.call(
        'no distiller agent configured — stored ${captures.length} raw '
        'entries in wearable memory',
      );
      return;
    }
    try {
      final distilled = await _runner(config, _buildPrompt(captures));
      if (distilled.trim().isEmpty) {
        throw StateError('distiller returned no text');
      }
      await _memory.append(
        content: distilled.trim(),
        startEpochMs: captures.first.startEpochMs,
        endEpochMs: _endOf(captures.last),
        source: 'distilled',
      );
      onLog?.call('distilled ${captures.length} captures into memory');
    } catch (e, s) {
      developer.log(
        'distillation failed; storing raw entries',
        name: 'wearable.pipeline',
        error: e,
        stackTrace: s,
      );
      await _storeVerbatim(captures);
      onLog?.call('distillation failed ($e) — stored raw entries instead');
    }
  }

  Future<SavedAgentConfig?> _distillerConfig() async {
    final id = await _settings.read(distillerAgentIdKey);
    if (id == null || id.isEmpty) return null;
    return _agents.getAgent(id);
  }

  Future<void> _storeVerbatim(List<ArchivedCapture> captures) async {
    for (final capture in captures) {
      await _memory.append(
        content: capture.resultText!,
        startEpochMs: capture.startEpochMs,
        endEpochMs: _endOf(capture),
        source: capture.kind == 'jpg' ? 'image' : 'transcript',
      );
    }
  }

  static int _endOf(ArchivedCapture capture) =>
      capture.startEpochMs + capture.durationMs;

  String _buildPrompt(List<ArchivedCapture> captures) {
    final buffer = StringBuffer()
      ..writeln(
        'You are distilling first-person observations from a wearable '
        'device (its microphone transcripts and camera snapshots) into '
        'concise memory notes for later recall.',
      )
      ..writeln(
        'Write a compact summary that preserves concrete facts: names, '
        'places, times, decisions, tasks mentioned, and anything the '
        'wearer would plausibly want to look up later. Note the time when '
        'it matters. Ignore filler and transcription noise. Respond with '
        'the notes only.',
      )
      ..writeln();
    for (final capture in captures) {
      final start = DateTime.fromMillisecondsSinceEpoch(capture.startEpochMs);
      final label = capture.kind == 'jpg' ? 'image' : 'audio';
      final approx = capture.timestampApproximate ? ' (time approximate)' : '';
      buffer
        ..writeln('[$start$approx, $label]')
        ..writeln(capture.resultText)
        ..writeln();
    }
    return buffer.toString();
  }
}

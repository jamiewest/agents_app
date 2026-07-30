import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/chat.dart'
    show PromptInspector, PromptSnapshot;

/// A [PromptInspector] that also mirrors each captured llama wire-format prompt
/// into the unified [PromptLog].
///
/// Registered in place of the plain inspector so local-model prompts appear in
/// the same log as cloud requests, while still exposing the latest snapshot for
/// any llama-specific UI.
class PromptLogInspector extends PromptInspector {
  /// Creates an inspector that mirrors snapshots into [log].
  PromptLogInspector(this.log, {this.title = 'local llama'});

  /// The unified prompt log this inspector mirrors into.
  final PromptLog log;

  /// Label used for captured local-model entries.
  final String title;

  @override
  void record(PromptSnapshot snapshot) {
    super.record(snapshot);
    log.add(
      PromptLogEntry(
        title: title,
        body: snapshot.text,
        capturedAt: snapshot.capturedAt,
        tags: <String>[
          '${snapshot.contextSize} ctx',
          'temp ${snapshot.temperature}',
          if (snapshot.topK != null) 'topK ${snapshot.topK}',
          if (snapshot.topP != null) 'topP ${snapshot.topP}',
          if (snapshot.seed != null) 'seed ${snapshot.seed}',
          'maxTokens ${snapshot.maxTokens}',
          if (snapshot.imageCount > 0) 'images ${snapshot.imageCount}',
          if (snapshot.stopSequences.isNotEmpty)
            'stop ${snapshot.stopSequences.join(' ')}',
        ],
      ),
    );
  }
}

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// One captured prompt: what was sent to a model, and how.
///
/// [body] is a human-readable rendering of the request — for local llama it is
/// the exact wire-format prompt (with control tokens); for cloud providers it
/// is a transcript of the system instructions, declared tools, and message
/// history that make up the request payload.
@immutable
class PromptLogEntry {
  /// Creates a log entry.
  const PromptLogEntry({
    required this.title,
    required this.body,
    required this.capturedAt,
    this.tags = const <String>[],
  });

  /// Short label identifying the model/provider, e.g. `anthropic · claude-…`.
  final String title;

  /// The rendered request text.
  final String body;

  /// Optional metadata chips (sampling config, image counts, stop sequences).
  final List<String> tags;

  /// When the prompt was captured.
  final DateTime capturedAt;
}

/// A rolling, newest-first log of every prompt sent to any model.
///
/// Both the local llama render seam and the [LoggingChatClient] decorator feed
/// this single store, so the in-app inspector shows local and cloud requests
/// together. Bounded to the most recent [_maxEntries] to cap memory.
class PromptLog extends ChangeNotifier {
  final List<PromptLogEntry> _entries = <PromptLogEntry>[];

  static const int _maxEntries = 50;

  /// Captured prompts, most recent first.
  List<PromptLogEntry> get entries =>
      List<PromptLogEntry>.unmodifiable(_entries.reversed);

  /// Records [entry] and notifies listeners, dropping the oldest if full.
  ///
  /// Also mirrors the prompt to the developer console (`name: 'prompt'`) so it
  /// is captured in logs/DevTools even when the in-app inspector isn't open.
  void add(PromptLogEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) _entries.removeAt(0);
    developer.log(entry.body, name: 'prompt', time: entry.capturedAt);
    notifyListeners();
  }

  /// Clears all captured prompts.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}

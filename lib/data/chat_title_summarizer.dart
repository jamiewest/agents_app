import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/logging.dart';
import 'package:extensions/system.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/conversation.dart';
import 'app_activity_monitor.dart';
import 'chat_transcript_store.dart';
import 'conversation_store.dart';

/// Names a conversation from its content using the resident local model.
///
/// Runs as a hosted [BackgroundService]: while the app is idle — foregrounded,
/// nothing generating, no recent user input — it walks conversations whose
/// title is still an auto-derived first-message stand-in and replaces each with
/// a short summarized title, marking it [ConversationTitleSource.summary].
///
/// It only ever reuses the model already resident in [LocalLlamaModelHost]
/// (via [residentTitleClient], which returns null when none is loaded), so it
/// never triggers a model load or eviction. It abandons a pass the instant the
/// user acts, so it never competes with foreground work.
final class ChatTitleSummarizer extends LoggedBackgroundService {
  /// Creates a summarizer.
  ChatTitleSummarizer({
    required this.conversations,
    required this.transcripts,
    required this.activity,
    required this.residentTitleClient,
    required super.loggerFactory,
    this.idleThreshold = const Duration(seconds: 30),
    this.checkInterval = const Duration(seconds: 10),
  }) : super(serviceName: 'ChatTitleSummarizer');

  /// Conversation metadata store (candidate list + title write-back).
  final ConversationStore conversations;

  /// Durable transcript reader, loaded off-view by conversation id.
  final ChatTranscriptStore transcripts;

  /// The idle signal that gates passes and cancels them on user activity.
  final AppActivityMonitor activity;

  /// Returns a chat client bound to the resident local model, or null when no
  /// local model is loaded (in which case nothing is summarized).
  final ai.ChatClient? Function() residentTitleClient;

  /// How long the app must be idle before a pass starts.
  final Duration idleThreshold;

  /// How often idleness is re-checked.
  final Duration checkInterval;

  @override
  Future<void> executeLogged(CancellationToken stoppingToken) async {
    // Register on the stopping token exactly once (rather than per tick) so its
    // callback list is not churned; [_sleep] and [_runPass] observe the shared
    // completed future instead.
    final stopped = Completer<void>();
    final registration = stoppingToken.register((_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    try {
      while (!stoppingToken.isCancellationRequested) {
        await _sleep(checkInterval, stopped.future);
        if (stoppingToken.isCancellationRequested) break;
        if (!activity.isIdle(threshold: idleThreshold)) continue;
        await _runPass(stoppingToken, stopped.future);
      }
    } finally {
      registration.dispose();
    }
  }

  /// Runs a single summarization pass. Exposed for tests; production drives
  /// passes through the idle-gated loop in [executeLogged].
  @visibleForTesting
  Future<void> runPassForTest(CancellationToken stoppingToken) {
    final stopped = Completer<void>();
    if (stoppingToken.isCancellationRequested) {
      stopped.complete();
    } else if (stoppingToken.canBeCanceled) {
      stoppingToken.register((_) {
        if (!stopped.isCompleted) stopped.complete();
      });
    }
    return _runPass(stoppingToken, stopped.future);
  }

  /// Titles every eligible conversation, one at a time, until the list is
  /// exhausted or the pass is cancelled by the host ([stopped]) or user
  /// activity.
  Future<void> _runPass(
    CancellationToken stoppingToken,
    Future<void> stopped,
  ) async {
    if (stoppingToken.isCancellationRequested) return;
    if (residentTitleClient() == null) return; // No resident model to reuse.

    // A fresh source per pass, cancelled by user activity or host shutdown, so
    // no single token's callback list accumulates across passes.
    final cts = CancellationTokenSource();
    var finished = false;
    final sub = activity.onActivity.listen((_) => cts.cancel());
    unawaited(
      stopped.then((_) {
        if (!finished) cts.cancel();
      }),
    );
    try {
      final token = cts.token;
      final candidates = (await conversations.listAll())
          .where(_needsTitle)
          .toList();
      for (final conversation in candidates) {
        if (stoppingToken.isCancellationRequested ||
            token.isCancellationRequested) {
          break;
        }
        // Re-resolve per candidate: if the resident model was evicted mid-pass
        // (e.g. a scheduled task swapped models), stop rather than reload it.
        final client = residentTitleClient();
        if (client == null) break;
        try {
          await _titleOne(conversation, client, token);
        } catch (e) {
          logger.logError('failed to title ${conversation.id}', error: e);
        }
        // Yield so cancellation and other microtasks get a turn between items.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      finished = true;
      await sub.cancel();
      cts.dispose();
    }
  }

  /// True while a conversation still carries an auto-derived title we may
  /// replace. Manual, group, task, and already-summarized titles are left be.
  bool _needsTitle(Conversation c) =>
      c.titleSource == ConversationTitleSource.firstMessage ||
      c.titleSource == ConversationTitleSource.none;

  Future<void> _titleOne(
    Conversation conversation,
    ai.ChatClient client,
    CancellationToken token,
  ) async {
    final entries = await transcripts.load(conversation.id);
    if (token.isCancellationRequested) return;

    final firstUser = _firstNonEmpty(entries, ai.ChatRole.user);
    final firstReply = _firstNonEmpty(entries, ai.ChatRole.assistant);
    // Immature: nothing meaningful to summarize until there is an exchange.
    if (firstUser.isEmpty || firstReply.isEmpty) return;

    final response = await client.getResponse(
      messages: _buildPrompt(firstUser, firstReply),
      options: ai.ChatOptions(maxOutputTokens: 28, temperature: 0.3),
      cancellationToken: token,
    );
    if (token.isCancellationRequested) return;

    final title = _sanitize(response.text);
    if (title.isEmpty) return;

    // Write-back race guard: the record may have been renamed, deleted, or
    // already summarized while we were generating. Only touch a still-eligible
    // one, and do not pass updatedAt so the recency-ordered list keeps its order.
    final fresh = await conversations.get(conversation.id);
    if (fresh == null || !_needsTitle(fresh)) return;
    await conversations.save(
      fresh.copyWith(
        title: title,
        titleSource: ConversationTitleSource.summary,
      ),
    );
    logger.logInformation('titled ${conversation.id}: "$title"');
  }

  /// The text of the first non-empty message with [role], or empty string.
  String _firstNonEmpty(List<TranscriptEntry> entries, ai.ChatRole role) {
    for (final entry in entries) {
      if (entry.message.role != role) continue;
      final text = entry.message.text.trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  List<ai.ChatMessage> _buildPrompt(String userText, String assistantText) {
    final body =
        'User: ${_clip(userText, 500)}\n'
        'Assistant: ${_clip(assistantText, 300)}';
    return [
      ai.ChatMessage.fromText(
        ai.ChatRole.system,
        'You write short chat titles. Reply with a concise title of 3 to 6 '
        'words that captures the topic. No quotes, no trailing punctuation, '
        'no preamble.',
      ),
      ai.ChatMessage.fromText(
        ai.ChatRole.user,
        'Write a title for this conversation:\n\n$body',
      ),
    ];
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  /// Reduces a raw model reply to a single clean title line. Exposed for tests.
  @visibleForTesting
  static String sanitizeTitle(String raw) => _sanitize(raw);

  /// Reduces a raw model reply to a single clean title line.
  static String _sanitize(String raw) {
    var t = raw.trim();
    final newline = t.indexOf('\n');
    if (newline >= 0) t = t.substring(0, newline).trim();
    t = t.replaceFirst(
      RegExp(r'^title\s*[:\-]\s*', caseSensitive: false),
      '',
    );
    t = _stripWrapping(t);
    t = t.replaceFirst(RegExp(r'[.!?,;:]+$'), '').trim();
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    if (t.length > 80) t = '${t.substring(0, 79).trimRight()}…';
    return t;
  }

  static const Set<String> _wrappingChars = {
    '"',
    "'",
    '`',
    '“',
    '”',
    '‘',
    '’',
  };

  static String _stripWrapping(String s) {
    var t = s.trim();
    while (t.isNotEmpty && _wrappingChars.contains(t[0])) {
      t = t.substring(1).trim();
    }
    while (t.isNotEmpty && _wrappingChars.contains(t[t.length - 1])) {
      t = t.substring(0, t.length - 1).trim();
    }
    return t;
  }

  /// Waits [duration], returning early when [cancelled] completes.
  static Future<void> _sleep(Duration duration, Future<void> cancelled) async {
    final ticked = Completer<void>();
    final timer = Timer(duration, () {
      if (!ticked.isCompleted) ticked.complete();
    });
    try {
      await Future.any([ticked.future, cancelled]);
    } finally {
      timer.cancel();
    }
  }
}

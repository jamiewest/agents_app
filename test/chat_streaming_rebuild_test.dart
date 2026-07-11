// Regression coverage for streaming repaint scoping: appending tokens to
// the live bubble must not rebuild completed message bubbles.

import 'dart:async';

import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_app/ui/views/llm_chat_view/llm_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_test_harness.dart';

void main() {
  testWidgets('completed bubbles do not rebuild per streamed token', (
    tester,
  ) async {
    final provider = _ScriptedProvider();
    // Seed one completed exchange; its bubble must stay quiet during the
    // next turn's streaming.
    final completed = ChatMessage.llm()..append('DONE earlier answer');
    provider.history = [ChatMessage.user('earlier', const []), completed];

    // The responseBuilder runs inside each bubble's per-message
    // ListenableBuilder, so its invocation count is the bubble body's build
    // count.
    final buildCounts = <String, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LlmChatView(
            provider: provider,
            responseBuilder: (context, text) {
              final key = text.startsWith('DONE') ? 'done' : 'live';
              buildCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
              return Text(text);
            },
            enableAttachments: false,
            enableVoiceNotes: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final doneBaseline = buildCounts['done'] ?? 0;

    await tester.enterText(find.byType(TextField), 'go');
    await tester.pump();
    await tester.tap(findSubmitButton());
    await tester.pump();

    for (var i = 0; i < 20; i++) {
      provider.emit('token-$i ');
      await tester.pump();
    }
    await provider.closeTurn();
    await tester.pumpAndSettle();

    // The live bubble repainted per token…
    expect(buildCounts['live'], greaterThanOrEqualTo(20));
    // …while the completed bubble rebuilt at most a handful of times
    // (initial + the structural turn start/end notifications) — not once
    // per token. Under the old whole-view setState this exceeds 20.
    expect(
      (buildCounts['done'] ?? 0) - doneBaseline,
      lessThanOrEqualTo(4),
      reason:
          'completed bubbles must not rebuild for every streamed token; '
          'counts: $buildCounts',
    );
  });
}

/// A provider whose streamed chunks are driven by the test.
final class _ScriptedProvider extends LlmProvider with ChangeNotifier {
  final List<ChatMessage> _history = [];
  StreamController<String>? _chunks;
  ChatMessage? _live;

  /// Streams [chunk] into the live bubble.
  void emit(String chunk) => _chunks!.add(chunk);

  /// Ends the live turn.
  Future<void> closeTurn() async {
    await _chunks!.close();
    _live!.isGenerating = false;
    notifyListeners();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) => throw UnimplementedError();

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) {
    final llmMessage = ChatMessage.llm();
    _history.addAll([ChatMessage.user(prompt, attachments), llmMessage]);
    _live = llmMessage;
    llmMessage.isGenerating = true;
    notifyListeners();

    final controller = StreamController<String>();
    _chunks = controller;
    return controller.stream.map((chunk) {
      llmMessage.append(chunk);
      return chunk;
    });
  }

  @override
  Iterable<ChatMessage> get history => _history;

  @override
  set history(Iterable<ChatMessage> history) {
    _history
      ..clear()
      ..addAll(history);
    notifyListeners();
  }
}

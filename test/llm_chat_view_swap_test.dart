// Provider-swap lifecycle: when the owner replaces the LlmProvider (an
// agent reload), LlmChatView must migrate its listeners and silently detach
// in-flight responses.

import 'dart:async';

import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_app/ui/views/llm_chat_view/llm_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_test_harness.dart';

void main() {
  Widget wrap(LlmProvider provider) => MaterialApp(
    home: Scaffold(
      body: LlmChatView(
        provider: provider,
        enableAttachments: false,
        enableVoiceNotes: false,
      ),
    ),
  );

  testWidgets('swapping providers moves listeners old → new', (tester) async {
    final first = _SwapProvider();
    final second = _SwapProvider();

    await tester.pumpWidget(wrap(first));
    await tester.pumpAndSettle();
    expect(first.listeners, isTrue);
    expect(second.listeners, isFalse);

    await tester.pumpWidget(wrap(second));
    await tester.pumpAndSettle();

    expect(first.listeners, isFalse);
    expect(second.listeners, isTrue);
  });

  testWidgets('an in-flight response detaches silently on swap', (
    tester,
  ) async {
    final first = _SwapProvider();
    final second = _SwapProvider();

    await tester.pumpWidget(wrap(first));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'go');
    await tester.pump();
    await tester.tap(findSubmitButton());
    await tester.pump();
    first.emit('partial ');
    await tester.pump();

    // Swap mid-stream (the FutureBuilder retry path can do this even while
    // busy). The old stream must stop being consumed without surfacing the
    // user-facing cancel snackbar.
    await tester.pumpWidget(wrap(second));
    await tester.pumpAndSettle();

    expect(first.turnCancelled, isTrue);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('CANCEL'), findsNothing);

    // The input is usable against the new provider.
    await tester.enterText(find.byType(TextField), 'again');
    await tester.pump();
    await tester.tap(findSubmitButton());
    await tester.pump();
    expect(second.sends, 1);
    // Give the bubble text before ending the turn so the jumping-dots
    // placeholder (an endless animation) is gone by the final pump.
    second.emit('ok');
    await tester.pump();
    await second.closeTurn();
    await tester.pumpAndSettle();
  });
}

/// A scripted provider that exposes listener state and upstream
/// cancellation for swap assertions.
final class _SwapProvider extends LlmProvider with ChangeNotifier {
  final List<ChatMessage> _history = [];
  StreamController<String>? _chunks;

  /// Whether anything is subscribed to this provider.
  bool get listeners => hasListeners;

  /// Whether a started turn's stream had its subscription cancelled.
  bool turnCancelled = false;

  /// How many sendMessageStream turns were started.
  int sends = 0;

  /// Streams [chunk] into the live turn.
  void emit(String chunk) => _chunks!.add(chunk);

  /// Ends the live turn.
  Future<void> closeTurn() async => _chunks!.close();

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
    sends++;
    final llmMessage = ChatMessage.llm();
    _history.addAll([ChatMessage.user(prompt, attachments), llmMessage]);
    notifyListeners();

    final controller = StreamController<String>(
      onCancel: () => turnCancelled = true,
    );
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

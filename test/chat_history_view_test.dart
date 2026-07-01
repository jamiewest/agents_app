import 'package:agents_app/ui/chat_view_model/chat_view_model.dart';
import 'package:agents_app/ui/chat_view_model/chat_view_model_provider.dart';
import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_app/ui/views/chat_history_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wraps the scrollable history in an edge fade shader', (
    tester,
  ) async {
    final provider = EchoProvider(
      history: [
        ChatMessage.user('hello', const []),
        ChatMessage(origin: MessageOrigin.llm, text: 'hi', attachments: []),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewModelProvider(
          viewModel: ChatViewModel(
            provider: provider,
            style: null,
            suggestions: const [],
            welcomeMessage: null,
            responseBuilder: null,
            messageSender: null,
            onMessageSubmitted: null,
            speechToText: null,
            enableAttachments: true,
            enableVoiceNotes: true,
          ),
          child: Scaffold(body: ChatHistoryView(onSelectSuggestion: (_) {})),
        ),
      ),
    );

    final shaderMask = tester.widget<ShaderMask>(find.byType(ShaderMask));

    expect(shaderMask.blendMode, BlendMode.dstIn);
    expect(
      find.descendant(
        of: find.byType(ShaderMask),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
  });
}

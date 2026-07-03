import 'package:agents_app/ui/chat_view_model/chat_view_model.dart';
import 'package:agents_app/ui/chat_view_model/chat_view_model_provider.dart';
import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_app/ui/views/chat_welcome_view.dart';
import 'package:agents_app/ui/views/llm_chat_view/llm_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(LlmProvider provider) => MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00658F)),
    ),
    home: Scaffold(
      body: LlmChatView(
        provider: provider,
        welcomeMessage: 'Welcome aboard',
        suggestions: const ['Try me'],
      ),
    ),
  );

  testWidgets('empty history shows the centered welcome view', (tester) async {
    // Arrange
    final provider = EchoProvider();

    // Act
    await tester.pumpWidget(app(provider));
    await tester.pumpAndSettle();

    // Assert
    expect(find.byType(ChatWelcomeView), findsOneWidget);
    expect(find.text('Welcome aboard'), findsOneWidget);
    expect(find.text('Try me'), findsOneWidget);
  });

  testWidgets('welcome view disappears once history has messages', (
    tester,
  ) async {
    // Arrange
    final provider = EchoProvider();
    await tester.pumpWidget(app(provider));
    await tester.pumpAndSettle();
    expect(find.byType(ChatWelcomeView), findsOneWidget);

    // Act
    provider.history = [
      ChatMessage.user('Hello there', const []),
      ChatMessage.llm()..append('Hi!'),
    ];
    await tester.pumpAndSettle();

    // Assert
    expect(find.byType(ChatWelcomeView), findsNothing);
    expect(find.text('Welcome aboard'), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('Hi!'), findsOneWidget);
  });

  testWidgets('tapping a suggestion forwards its text', (tester) async {
    // Arrange
    String? selected;
    final viewModel = ChatViewModel(
      provider: EchoProvider(),
      style: null,
      suggestions: const ['Try me'],
      welcomeMessage: 'Hi',
      responseBuilder: null,
      messageSender: null,
      onMessageSubmitted: null,
      speechToText: null,
      enableAttachments: false,
      enableVoiceNotes: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatViewModelProvider(
            viewModel: viewModel,
            child: ChatWelcomeView(
              welcomeMessage: 'Hi',
              suggestions: const ['Try me'],
              onSelectSuggestion: (s) => selected = s,
            ),
          ),
        ),
      ),
    );

    // Act
    await tester.tap(find.text('Try me'));
    await tester.pump();

    // Assert
    expect(selected, 'Try me');
  });
}

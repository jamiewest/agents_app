import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_app/main.dart';
import 'package:agents_app/ui/views/action_button.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_app/ui/views/chat_input/input_state.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installConnectivityMocks);

  group('ChatScreen', () {
    testWidgets('defaults a new conversation title to the first message', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'Summarize the design direction',
      );
      await tester.pump();
      expect(
        tester.widget<InputButton>(find.byType(InputButton)).inputState,
        InputState.canSubmitPrompt,
      );
      await tester.tap(find.byType(ActionButton));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        find.text('Summarize the design direction'),
        findsAtLeastNWidgets(1),
      );

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Summarize the design direction');
      expect(
        conversations.single.titleSource,
        ConversationTitleSource.firstMessage,
      );
    });

    testWidgets('persists the transcript through the history provider', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'First question');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pump();
      // The harness pipeline touches real async (plugin channels); drive it
      // with the real event loop before checking persisted state.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(testAgent.id);
      final transcript = await ChatTranscriptStore(
        records,
      ).load(conversations.single.id);

      expect(transcript.map((e) => e.message.text), ['First question', 'ok']);
      expect(transcript.last.senderAgentId, testAgent.id);

      await tester.pumpAndSettle();
    });

    testWidgets('a resumed conversation sends prior context to the model', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final capturing = CapturingChatClient();
      final services = buildTestServices(records, chatClient: capturing);
      await seedTestAgent(services);

      // First visit: establish some history.
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My name is Jamie');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final conversationId = (await ConversationStore(
        records,
      ).listForAgent(testAgent.id)).single.id;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // Second visit: resume and send a follow-up.
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            agent: testAgent,
            services: services,
            conversationId: conversationId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Appears as both the restored chat bubble and the app-bar title.
      expect(find.text('My name is Jamie'), findsAtLeastNWidgets(1));

      await tester.enterText(find.byType(TextField), 'What is my name?');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final texts = capturing.lastRequestMessages
          .map((message) => message.text)
          .toList();
      expect(texts, contains('My name is Jamie'));
      expect(texts, contains('What is my name?'));
      expect(texts.indexOf('My name is Jamie'), lessThan(3));

      await tester.pumpAndSettle();
    });

    testWidgets('consolidates conversation actions into one overflow menu', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();

      // The old individual icon buttons are gone from the app bar.
      expect(find.byIcon(Icons.group_add_outlined), findsNothing);
      expect(find.byIcon(Icons.restart_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);

      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();

      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Add agent to chat'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete conversation'), findsOneWidget);
    });

    testWidgets('a private chat hides the conversation actions menu', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            agent: testAgent,
            services: services,
            isPrivate: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Conversation actions'), findsNothing);
    });
  });
}

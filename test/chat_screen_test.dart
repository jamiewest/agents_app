import 'package:agents_app/data/app_activity_monitor.dart';
import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/agent_task.dart' show taskPromptAuthorName;
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_app/main.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_app/ui/views/chat_input/input_state.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
      await tester.tap(findSubmitButton());
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
      await tester.tap(findSubmitButton());
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
      await tester.tap(findSubmitButton());
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
      await tester.tap(findSubmitButton());
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

    testWidgets('applies a config edit to the live agent mid-conversation', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final capturing = CapturingChatClient();
      final services = buildTestServices(records, chatClient: capturing);
      await seedTestAgent(services);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();

      // First turn with the seeded (instruction-less) config.
      await tester.enterText(find.byType(TextField), 'First question');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      // The harness composes a base system prompt; the seeded agent adds no
      // instructions of its own yet.
      expect(
        capturing.lastRequestOptions?.instructions,
        isNot(contains('pirate')),
      );

      // Edit the agent behind this chat. Instructions stand in for any
      // rebuilt config field — tool access flags flow through the same
      // factory path — and are directly observable on the request options.
      await tester.runAsync(
        () => manager.saveAgent(
          testAgent.copyWith(instructions: 'You are a pirate.'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      // Second turn: the swapped-in agent carries the new instructions
      // without leaving the conversation.
      await tester.enterText(find.byType(TextField), 'Second question');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      expect(
        capturing.lastRequestOptions?.instructions,
        contains('You are a pirate.'),
      );
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
      expect(find.byIcon(LucideIcons.userPlus300), findsNothing);
      expect(find.byIcon(LucideIcons.rotateCcw300), findsNothing);
      expect(find.byIcon(LucideIcons.pencil300), findsNothing);

      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();

      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Start group chat…'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete conversation'), findsOneWidget);
    });

    testWidgets('hides task prompts from the displayed transcript', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);

      const conversationId = 'task-conv';
      await ConversationStore(records).save(
        testConversation(
          id: conversationId,
          title: 'Task: Digest',
          updatedAt: DateTime.utc(2026, 7, 2, 9),
        ),
      );

      Future<void> seedMessage(int seq, ai.ChatMessage message) =>
          records.put(ChatMessageRecords.collection, '$conversationId-$seq', {
            ChatMessageRecords.conversationIdField: conversationId,
            ChatMessageRecords.sessionIdField: 'task-run',
            ChatMessageRecords.seqField: seq,
            ChatMessageRecords.senderAgentIdField: testAgent.id,
            ChatMessageRecords.messageField: ChatMessageCodec.encode(message),
          });

      // A hidden-user prompt, a system-role prompt, and the agent's reply.
      // Both prompt forms must stay out of the rendered transcript.
      await seedMessage(
        0,
        ai.ChatMessage(
          role: ai.ChatRole.user,
          contents: [ai.TextContent('SECRET PROMPT')],
          authorName: taskPromptAuthorName,
        ),
      );
      await seedMessage(
        1,
        ai.ChatMessage.fromText(ai.ChatRole.system, 'SYSTEM SIDE'),
      );
      await seedMessage(
        2,
        ai.ChatMessage.fromText(ai.ChatRole.assistant, 'the result'),
      );

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

      expect(find.text('the result'), findsAtLeastNWidgets(1));
      expect(find.text('SECRET PROMPT'), findsNothing);
      expect(find.text('SYSTEM SIDE'), findsNothing);
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

    testWidgets('a reloaded agent still brackets the idle monitor', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final monitor = AppActivityMonitor();
      final services = buildTestServices(
        records,
        chatClient: BlockingChatClient(),
        activityMonitor: monitor,
      );
      await seedTestAgent(services);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: testAgent, services: services),
        ),
      );
      await tester.pumpAndSettle();

      // Edit the agent so the chat swaps in a rebuilt provider.
      await tester.runAsync(
        () => manager.saveAgent(
          testAgent.copyWith(instructions: 'You are a pirate.'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      // A turn on the replacement provider must raise the app-wide
      // inference signal; without it, background work (e.g. the title
      // summarizer) could run mid-generation after any reload.
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(findSubmitButton());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );

      expect(monitor.isInferenceInFlight, isTrue);

      // Unmount while the scripted model never answers; the pending bubble
      // animation would otherwise outlive the test.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

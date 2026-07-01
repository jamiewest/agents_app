import 'package:agents_app/main.dart';
import 'package:agents_app/ui/chat_sessions/chat_session_record.dart';
import 'package:agents_app/ui/chat_sessions/chat_session_store.dart';
import 'package:agents_app/ui/providers/providers.dart' as ui;
import 'package:agents_app/ui/views/action_button.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_app/ui/views/chat_input/input_state.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);

const _model = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'fake-model',
);

const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Test Agent',
  modelId: 'model-1',
);

ServiceProvider _buildServices(InMemoryKeyValueStore kv) {
  final services = ServiceCollection()
    ..addConfiguredAgents(
      keyValueStore: (_) => kv,
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            _EchoChatClient(),
      ),
    );
  return services.buildServiceProvider();
}

Future<void> _seedAgent(ServiceProvider services) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_source);
  await manager.saveModel(_model);
  await manager.saveAgent(_agent);
}

Widget _host(ServiceProvider services) => MaterialApp(
  home: AgentConversationsScreen(agent: _agent, services: services),
);

ChatSessionRecord _conversation({
  required String id,
  required String title,
  required DateTime updatedAt,
  int messageCount = 1,
}) => ChatSessionRecord(
  id: id,
  agentId: _agent.id,
  title: title,
  titleSource: ChatSessionTitleSource.firstMessage,
  history: [
    for (var i = 0; i < messageCount; i++)
      ui.ChatMessage.user('message $i', const []),
  ],
  createdAt: DateTime.utc(2026, 6, 30, 9),
  updatedAt: updatedAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentConversationsScreen', () {
    testWidgets('discards a new chat when no message is sent', (tester) async {
      final kv = InMemoryKeyValueStore();
      final services = _buildServices(kv);
      await _seedAgent(services);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('No conversations yet.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'New chat'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('Ask Test Agent anything.'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ChatSessionStore(kv).list(_agent.id);
      expect(conversations, isEmpty);
      expect(find.text('No conversations yet.'), findsOneWidget);
    });

    testWidgets(
      'shows a new chat when the user backs out immediately after sending',
      (tester) async {
        final kv = InMemoryKeyValueStore();
        final services = _buildServices(kv);
        await _seedAgent(services);

        await tester.pumpWidget(_host(services));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Remember this chat');
        await tester.pump();
        await tester.tap(find.byType(ActionButton));
        await tester.pump();

        await tester.pageBack();
        await tester.pumpAndSettle();

        final conversations = await ChatSessionStore(kv).list(_agent.id);
        expect(conversations, hasLength(1));
        expect(conversations.single.title, 'Remember this chat');
        expect(find.text('Remember this chat'), findsOneWidget);
        expect(find.textContaining('1 message'), findsOneWidget);
      },
    );

    testWidgets('lists conversations newest first with counts', (tester) async {
      final kv = InMemoryKeyValueStore();
      final services = _buildServices(kv);
      final store = ChatSessionStore(kv);
      await store.save(
        _conversation(
          id: 'older',
          title: 'Older chat',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );
      await store.save(
        _conversation(
          id: 'newer',
          title: 'Newer chat',
          updatedAt: DateTime.utc(2026, 6, 30, 12),
          messageCount: 2,
        ),
      );

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Newer chat'), findsOneWidget);
      expect(find.text('Older chat'), findsOneWidget);
      expect(find.textContaining('2 messages'), findsOneWidget);
      expect(find.textContaining('1 message'), findsOneWidget);

      final newerTop = tester.getTopLeft(find.text('Newer chat')).dy;
      final olderTop = tester.getTopLeft(find.text('Older chat')).dy;
      expect(newerTop, lessThan(olderTop));
    });

    testWidgets('renames and deletes a conversation from the list', (
      tester,
    ) async {
      final kv = InMemoryKeyValueStore();
      final services = _buildServices(kv);
      final store = ChatSessionStore(kv);
      await store.save(
        _conversation(
          id: 'conversation-1',
          title: 'Original title',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Manual title');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      var loaded = await store.load('conversation-1');
      expect(loaded!.title, 'Manual title');
      expect(loaded.titleSource, ChatSessionTitleSource.manual);
      expect(find.text('Manual title'), findsOneWidget);

      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      loaded = await store.load('conversation-1');
      expect(loaded, isNull);
      expect(find.text('No conversations yet.'), findsOneWidget);
    });
  });

  group('ChatScreen', () {
    testWidgets('defaults a new conversation title to the first message', (
      tester,
    ) async {
      final kv = InMemoryKeyValueStore();
      final services = _buildServices(kv);
      await _seedAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: _agent, services: services),
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

      final conversations = await ChatSessionStore(kv).list(_agent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Summarize the design direction');
      expect(
        conversations.single.titleSource,
        ChatSessionTitleSource.firstMessage,
      );
    });
  });
}

final class _EchoChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(
    messages: <ai.ChatMessage>[
      ai.ChatMessage.fromText(ai.ChatRole.assistant, 'ok'),
    ],
  );

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => Stream<ai.ChatResponseUpdate>.value(
    ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok'),
  );

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

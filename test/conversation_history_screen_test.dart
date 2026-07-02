import 'dart:async';

import 'package:agents/agents.dart' show InMemoryAgentFileStore;
import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_app/main.dart';
import 'package:agents_app/ui/views/action_button.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_app/ui/views/chat_input/input_state.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

ServiceProvider _buildServices(
  InMemoryRecordStore records, {
  ai.ChatClient? chatClient,
}) {
  final services = ServiceCollection()
    ..addRecordStore(recordStore: (_) => records)
    ..addConfiguredAgents(
      keyValueStore: (_) => InMemoryKeyValueStore(),
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            chatClient ?? _EchoChatClient(),
      ),
      // The native harness defaults hit the real file system (skills scan,
      // file memory/access stores) and platform plugins (connectivity,
      // timezone, device/app info), none of which exist in the test
      // environment. Keep everything in memory and hermetic.
      configureHarness: (options) => options
        ..disableAgentSkillsProvider = true
        ..fileMemoryStore = InMemoryAgentFileStore()
        ..fileAccessStore = InMemoryAgentFileStore()
        ..enableConnectivity = false
        ..enableTemporal = false
        ..enableAppInfo = false
        ..enableDeviceInfo = false,
      configureHarnessForScope: (sp) => (agent, options, scope) {
        if (scope.isPrivate) return;
        options.chatHistoryProvider = FlutterChatHistoryProvider(
          sp.getRequiredService<RecordStore>(),
          conversationId: scope.conversationId,
          sessionIdResolver: scope.sessionIdResolver,
          senderAgentId: agent.id,
        );
      },
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

Conversation _conversation({
  required String id,
  required String title,
  required DateTime updatedAt,
  String agentId = 'agent-1',
  String? preview,
}) => Conversation(
  id: id,
  kind: ConversationKind.direct,
  title: title,
  titleSource: ConversationTitleSource.firstMessage,
  participantAgentIds: [agentId],
  createdAt: DateTime.utc(2026, 6, 30, 9),
  updatedAt: updatedAt,
  lastMessagePreview: preview,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The harness constructs a ConnectivityMonitor unconditionally; give the
    // connectivity_plus channels mock handlers so its event-channel
    // activation does not surface a MissingPluginException through
    // FlutterError and fail unrelated tests.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => 'wifi',
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success('wifi'),
      ),
    );
  });

  group('AgentConversationsScreen', () {
    testWidgets('discards a new chat when no message is sent', (tester) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(records);
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

      final conversations = await ConversationStore(
        records,
      ).listForAgent(_agent.id);
      expect(conversations, isEmpty);
      expect(find.text('No conversations yet.'), findsOneWidget);
    });

    testWidgets(
      'shows a new chat when the user backs out immediately after sending',
      (tester) async {
        final records = InMemoryRecordStore();
        final services = _buildServices(records);
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

        final conversations = await ConversationStore(
          records,
        ).listForAgent(_agent.id);
        expect(conversations, hasLength(1));
        expect(conversations.single.title, 'Remember this chat');
        expect(find.text('Remember this chat'), findsAtLeastNWidgets(1));
      },
    );

    testWidgets('saves the user message when backing out mid-response', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(
        records,
        chatClient: _BlockingChatClient(),
      );
      await _seedAgent(services);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Save before answering');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pump();

      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(_agent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Save before answering');
      expect(conversations.single.lastMessagePreview, 'Save before answering');
      expect(find.text('Save before answering'), findsAtLeastNWidgets(1));
    });

    testWidgets('saves the conversation as soon as send is tapped', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(
        records,
        chatClient: _BlockingChatClient(),
      );
      await _seedAgent(services);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Saved on submit');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pump();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(_agent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Saved on submit');
      expect(conversations.single.lastMessagePreview, 'Saved on submit');
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('keeps a submit-saved conversation when popping immediately', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(
        records,
        chatClient: _BlockingChatClient(),
      );
      await _seedAgent(services);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Do not delete me');
      await tester.pump();
      await tester.tap(find.byType(ActionButton));
      await tester.pageBack();
      await tester.pumpAndSettle();

      final conversations = await ConversationStore(
        records,
      ).listForAgent(_agent.id);
      expect(conversations, hasLength(1));
      expect(conversations.single.title, 'Do not delete me');
      expect(find.text('Do not delete me'), findsAtLeastNWidgets(1));
    });

    testWidgets('lists conversations newest first with previews', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(records);
      final store = ConversationStore(records);
      await store.save(
        _conversation(
          id: 'older',
          title: 'Older chat',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
          preview: 'older preview',
        ),
      );
      await store.save(
        _conversation(
          id: 'newer',
          title: 'Newer chat',
          updatedAt: DateTime.utc(2026, 6, 30, 12),
          preview: 'newer preview',
        ),
      );

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Newer chat'), findsOneWidget);
      expect(find.text('Older chat'), findsOneWidget);
      expect(find.textContaining('newer preview'), findsOneWidget);
      expect(find.textContaining('older preview'), findsOneWidget);

      final newerTop = tester.getTopLeft(find.text('Newer chat')).dy;
      final olderTop = tester.getTopLeft(find.text('Older chat')).dy;
      expect(newerTop, lessThan(olderTop));
    });

    testWidgets(
      'falls back to all saved conversations when agent list is empty',
      (tester) async {
        final records = InMemoryRecordStore();
        final services = _buildServices(records);
        await ConversationStore(records).save(
          _conversation(
            id: 'saved-for-other-agent',
            title: 'Visible fallback chat',
            agentId: 'other-agent',
            updatedAt: DateTime.utc(2026, 6, 30, 9),
          ),
        );

        await tester.pumpWidget(_host(services));
        await tester.pumpAndSettle();

        expect(find.text('Visible fallback chat'), findsOneWidget);
        expect(find.text('No conversations yet.'), findsNothing);
      },
    );

    testWidgets('renames and deletes a conversation from the list', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(records);
      final store = ConversationStore(records);
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

      var loaded = await store.get('conversation-1');
      expect(loaded!.title, 'Manual title');
      expect(loaded.titleSource, ConversationTitleSource.manual);
      expect(find.text('Manual title'), findsOneWidget);

      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      loaded = await store.get('conversation-1');
      expect(loaded, isNull);
      expect(find.text('No conversations yet.'), findsOneWidget);
    });
  });

  group('ChatScreen', () {
    testWidgets('defaults a new conversation title to the first message', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = _buildServices(records);
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

      final conversations = await ConversationStore(
        records,
      ).listForAgent(_agent.id);
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
      final services = _buildServices(records);
      await _seedAgent(services);

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: _agent, services: services),
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
      ).listForAgent(_agent.id);
      final transcript = await ChatTranscriptStore(
        records,
      ).load(conversations.single.id);

      expect(transcript.map((e) => e.message.text), ['First question', 'ok']);
      expect(transcript.last.senderAgentId, _agent.id);

      await tester.pumpAndSettle();
    });

    testWidgets('a resumed conversation sends prior context to the model', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final capturing = _CapturingChatClient();
      final services = _buildServices(records, chatClient: capturing);
      await _seedAgent(services);

      // First visit: establish some history.
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(agent: _agent, services: services),
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
      ).listForAgent(_agent.id)).single.id;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // Second visit: resume and send a follow-up.
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            agent: _agent,
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

final class _CapturingChatClient extends ai.ChatClient {
  List<ai.ChatMessage> lastRequestMessages = const [];

  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    lastRequestMessages = messages.toList();
    return ai.ChatResponse(
      messages: <ai.ChatMessage>[
        ai.ChatMessage.fromText(ai.ChatRole.assistant, 'ok'),
      ],
    );
  }

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    lastRequestMessages = messages.toList();
    yield ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok');
  }

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

final class _BlockingChatClient extends ai.ChatClient {
  final _blocked = Completer<void>();

  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    await _blocked.future;
    return ai.ChatResponse(messages: const <ai.ChatMessage>[]);
  }

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    await _blocked.future;
  }

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

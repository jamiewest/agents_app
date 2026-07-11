// Shared fixtures for chat-related widget tests: hermetic services,
// seeded agent config, and fake chat clients.

import 'dart:async';

import 'package:agents/agents.dart' show InMemoryAgentFileStore;
import 'package:agents_app/data/app_activity_monitor.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_app/ui/views/action_button.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds the chat input's submit button.
///
/// With attachments enabled the chat input renders two [ActionButton]s
/// (attach and submit), so tests must target the one inside [InputButton].
Finder findSubmitButton() => find.descendant(
  of: find.byType(InputButton),
  matching: find.byType(ActionButton),
);

/// The seeded model source.
const testSource = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);

/// The seeded model.
const testModel = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'fake-model',
);

/// The seeded agent.
const testAgent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Test Agent',
  modelId: 'model-1',
);

/// Builds a hermetic service provider over [records].
///
/// The native harness defaults hit the real file system (skills scan,
/// file memory/access stores) and platform plugins (connectivity,
/// timezone, device/app info), none of which exist in the test
/// environment. Keep everything in memory.
ServiceProvider buildTestServices(
  InMemoryRecordStore records, {
  ai.ChatClient? chatClient,
  AppActivityMonitor? activityMonitor,
}) {
  final services = ServiceCollection()
    ..addRecordStore(recordStore: (_) => records)
    ..tryAddSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    )
    ..addConfiguredAgents(
      keyValueStore: (_) => InMemoryKeyValueStore(),
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            chatClient ?? EchoChatClient(),
      ),
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
  if (activityMonitor != null) {
    services.tryAddSingleton<AppActivityMonitor>((_) => activityMonitor);
  }
  return services.buildServiceProvider();
}

/// Saves [testSource], [testModel], and [testAgent].
Future<void> seedTestAgent(ServiceProvider services) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(testSource);
  await manager.saveModel(testModel);
  await manager.saveAgent(testAgent);
}

/// Builds a direct conversation record for seeding stores.
Conversation testConversation({
  required String id,
  required String title,
  required DateTime updatedAt,
  String agentId = 'agent-1',
  String? preview,
  String? channelId,
}) => Conversation(
  id: id,
  kind: ConversationKind.direct,
  title: title,
  titleSource: ConversationTitleSource.firstMessage,
  participantAgentIds: [agentId],
  channelId: channelId,
  createdAt: DateTime.utc(2026, 6, 30, 9),
  updatedAt: updatedAt,
  lastMessagePreview: preview,
);

/// Mocks the connectivity_plus channels.
///
/// The harness constructs a ConnectivityMonitor unconditionally; without
/// handlers its event-channel activation surfaces a
/// MissingPluginException through FlutterError and fails unrelated tests.
void installConnectivityMocks() {
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
}

/// Replies 'ok' to every request immediately.
final class EchoChatClient extends ai.ChatClient {
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

/// Records the messages and options of the last request it received.
final class CapturingChatClient extends ai.ChatClient {
  /// The messages sent with the most recent request.
  List<ai.ChatMessage> lastRequestMessages = const [];

  /// The options sent with the most recent request.
  ai.ChatOptions? lastRequestOptions;

  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    lastRequestMessages = messages.toList();
    lastRequestOptions = options;
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
    lastRequestOptions = options;
    yield ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok');
  }

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

/// Never answers; requests hang until the test ends.
final class BlockingChatClient extends ai.ChatClient {
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

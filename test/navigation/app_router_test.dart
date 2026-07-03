import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/navigation/app_bootstrap.dart';
import 'package:agents_app/navigation/app_router.dart';
import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_app/ui/screens/chats_home.dart';
import 'package:agents_app/ui/screens/onboarding_screen.dart';
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

ServiceProvider _buildServices() {
  final kv = InMemoryKeyValueStore();
  final services = ServiceCollection()
    ..addSingleton<ThemeSettings>((_) => ThemeSettings(kv))
    ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
    ..addConfiguredAgents(
      keyValueStore: (_) => InMemoryKeyValueStore(),
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            _NullChatClient(),
      ),
    );
  return services.buildServiceProvider();
}

Future<void> _seedUsableAgent(ServiceProvider services) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_source);
  await manager.saveModel(_model);
  await manager.saveAgent(_agent);
}

Widget _app(ServiceProvider services, {String initialLocation = '/chats'}) =>
    MaterialApp.router(
      routerConfig: createAppRouter(
        services: services,
        bootstrap: AppBootstrap(services),
        scheduler: TaskSchedulerService(services),
        initialLocation: initialLocation,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('app router', () {
    testWidgets('redirects to onboarding when no usable agent exists', (
      tester,
    ) async {
      final services = _buildServices();

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.text('Add your first agent'), findsOneWidget);
    });

    testWidgets('opens chats when a usable agent exists', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();

      expect(find.byType(ChatsHome), findsOneWidget);
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('onboarding routes into the add-agent wizard', (tester) async {
      final services = _buildServices();

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('API agent'));
      await tester.pumpAndSettle();

      expect(find.byType(AddAgentWizard), findsOneWidget);
      expect(find.textContaining('Provider'), findsWidgets);
    });

    testWidgets('keeps onboarding until an agent exists, then unlocks', (
      tester,
    ) async {
      final services = _buildServices();

      await tester.pumpWidget(_app(services, initialLocation: '/tasks'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);

      await _seedUsableAgent(services);
      await tester.pumpWidget(_app(services, initialLocation: '/tasks'));
      await tester.pumpAndSettle();

      expect(find.text('No tasks yet.', findRichText: true), findsNothing);
      expect(find.byType(OnboardingScreen), findsNothing);
    });

    testWidgets('shell shows a navigation rail on wide layouts', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      // The rail must not starve the body: text finders still match
      // zero-width widgets, so assert real geometry.
      expect(tester.getSize(find.byType(ChatsHome)).width, greaterThan(1000));
      expect(tester.getSize(find.byType(NavigationRail)).width, lessThan(260));
    });

    testWidgets('shell shows a bottom bar on compact layouts', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('switching branches preserves the shell', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();

      expect(find.text('No tasks yet.', findRichText: true), findsNothing);
      expect(find.textContaining('No tasks yet'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Agents & providers'), findsOneWidget);
    });
  });
}

final class _NullChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(messages: const []);

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => const Stream.empty();

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

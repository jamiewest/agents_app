import 'dart:io' as io;

import 'package:agents_app/features/local_models/local_model_store_io.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/app/app_bootstrap.dart';
import 'package:agents_app/app/app_router.dart';
import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_app/ui/screens/chats_home.dart';
import 'package:agents_app/ui/screens/onboarding_screen.dart';
import 'package:agents_app/ui/screens/settings_home_screen.dart';
import 'package:agents_app/ui/widgets/settings_section_shell.dart';
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
    ..addSingleton<UserProfileSettings>((_) => UserProfileSettings(kv))
    ..addSingleton<PushoverSettings>(
      (sp) => PushoverSettings(sp.getRequiredService<SecretStore>()),
    )
    ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
    ..addSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    )
    ..addSingleton<AgentRunTelemetryStore>(
      (sp) => AgentRunTelemetryStore(sp.getRequiredService<RecordStore>()),
    )
    ..addConfiguredAgents(
      keyValueStore: (_) => InMemoryKeyValueStore(),
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver:
            ({required source, required model, httpClient, scope}) =>
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

  // Root the local model store in a temp directory: bootstrap's restore pass
  // would otherwise call path_provider, whose platform channel never answers
  // in widget tests.
  late io.Directory storeRoot;
  setUp(() {
    storeRoot = io.Directory.systemTemp.createTempSync('app_router_test');
    debugLocalModelStoreRoot = storeRoot;
  });
  tearDown(() {
    debugLocalModelStoreRoot = null;
    storeRoot.deleteSync(recursive: true);
  });

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
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('API agent'));
      await tester.pumpAndSettle();

      expect(find.byType(AddAgentWizard), findsOneWidget);
      expect(find.textContaining('Provider'), findsWidgets);
      // Setup during onboarding is full-screen: no shell rail around it,
      // even at widths where the shell would show one.
      expect(find.byType(NavigationRail), findsNothing);
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

      expect(find.text('No scheduled tasks yet.'), findsOneWidget);
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

    testWidgets('shell shows a hamburger-opened drawer on compact layouts', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);

      // The page header's hamburger opens the drawer: the brand mark at the
      // top, the top-level destinations at the bottom, and — because the
      // Chats screen already shows them on this width — no conversations.
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.byType(AgentTeamsBrand),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.byType(ChatsListView),
        ),
        findsNothing,
      );

      // Picking a destination closes the drawer and switches branch.
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.textContaining('No scheduled tasks yet'), findsOneWidget);
    });

    testWidgets('switching branches preserves the shell', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();

      expect(find.text('No scheduled tasks yet.'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Agent Center'), findsOneWidget);
    });

    // Logs & diagnostics is entered by branch switch rather than a push, so
    // nothing pops it; its header carries an explicit back button.
    for (final (label, width) in [('wide', 1200.0), ('compact', 420.0)]) {
      testWidgets('Logs & diagnostics goes back to settings home ($label)', (
        tester,
      ) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        for (final location in [
          '/settings/logging',
          '/settings/logging/prompts',
        ]) {
          await tester.pumpWidget(_app(services, initialLocation: location));
          await tester.pumpAndSettle();
          expect(
            find.byType(SettingsHomeScreen),
            findsNothing,
            reason: location,
          );

          await tester.tap(find.byType(SettingsBackButton));
          await tester.pumpAndSettle();

          expect(
            find.byType(SettingsHomeScreen),
            findsOneWidget,
            reason: location,
          );
        }
      });
    }

    // Appearance and Profile are pushed sub-pages of Settings, so back is a
    // real pop; the shared header still spells the destination out.
    for (final (label, path) in [
      ('Appearance', '/settings/appearance'),
      ('Profile', '/settings/profile'),
    ]) {
      testWidgets('$label opens from Settings and comes back', (tester) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        tester.view.physicalSize = const Size(1200, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_app(services, initialLocation: '/settings'));
        await tester.pumpAndSettle();

        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHomeScreen), findsNothing);
        expect(find.text(label), findsOneWidget, reason: path);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHomeScreen), findsOneWidget);
      });
    }

    // The Agent Center and Logs are sibling routes entered with `go`, not
    // pages pushed onto a stack, so there is no direction to slide along.
    // Both directions cross-fade, and the shell keeps one page identity
    // across its tabs — a per-location key would remount it on every tab.
    testWidgets('a section is entered, switched, and left without remounting '
        'or colliding page keys', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agent Center'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomeScreen), findsNothing);
      final shell = tester.element(find.byType(SettingsSectionShell));

      await tester.tap(find.text('Models'));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byType(SettingsSectionShell)),
        same(shell),
        reason: 'switching tabs must not remount the section',
      );

      await tester.tap(find.byType(SettingsBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Settings home no longer hosts appearance controls or a '
        'network-sharing row', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();

      // Appearance is a row now, not a block of swatches and segments.
      expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
      // Sharing moved onto each agent's own page.
      expect(find.text('Share agents on the network'), findsNothing);
      // The embedding picker is gone; memory search is keyword matching.
      expect(find.text('Memory embedding model'), findsNothing);
    });
  });

  group('user profile', () {
    test('an empty profile contributes no instructions', () async {
      final settings = UserProfileSettings(InMemoryKeyValueStore());
      await settings.load();
      expect(settings.isConfigured, isFalse);
      expect(settings.instructions, isNull);
    });

    test('a saved profile round-trips and reads as context', () async {
      final store = InMemoryKeyValueStore();
      final settings = UserProfileSettings(store);
      await settings.save(name: '  Jamie  ', bio: '  Builds Flutter apps.  ');

      expect(settings.name, 'Jamie');
      expect(settings.instructions, contains('Their name is Jamie.'));
      expect(settings.instructions, contains('Builds Flutter apps.'));

      // Survives a restart: the next launch loads it from storage.
      final reloaded = UserProfileSettings(store);
      await reloaded.load();
      expect(reloaded.name, 'Jamie');
      expect(reloaded.bio, 'Builds Flutter apps.');
    });

    test('clearing both fields removes the profile again', () async {
      final store = InMemoryKeyValueStore();
      final settings = UserProfileSettings(store);
      await settings.save(name: 'Jamie', bio: 'Builds things.');
      await settings.save(name: '', bio: '');

      final reloaded = UserProfileSettings(store);
      await reloaded.load();
      expect(reloaded.isConfigured, isFalse);
      expect(reloaded.instructions, isNull);
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

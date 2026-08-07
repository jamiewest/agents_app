import 'dart:io' as io;

import 'package:agents_app/features/local_models/local_model_store_io.dart';
import 'package:agents_app/data/chat_settings.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/app/app_bootstrap.dart';
import 'package:agents_app/app/app_router.dart';
import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_app/ui/screens/agent_center_shell.dart';
import 'package:agents_app/ui/screens/chats_home.dart';
import 'package:agents_app/ui/screens/appearance_settings_screen.dart';
import 'package:agents_app/ui/screens/onboarding_screen.dart';
import 'package:agents_app/ui/screens/profile_settings_screen.dart';
import 'package:agents_app/ui/screens/settings_home_screen.dart';
import 'package:agents_app/ui/widgets/settings_section_shell.dart';
import 'package:agents_app/ui/widgets/settings_shell.dart';
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
    ..addSingleton<AppInfo>(
      (_) => AppInfo()
        ..populate(
          appName: 'Agent Teams',
          packageName: 'dev.example.agents',
          version: '9.9.9',
          buildNumber: '42',
        ),
    )
    ..addSingleton<ThemeSettings>((_) => ThemeSettings(kv))
    ..addSingleton<ChatSettings>((_) => ChatSettings(kv))
    ..addSingleton<UserProfileSettings>((_) => UserProfileSettings(kv))
    ..addSingleton<PushoverSettings>(
      (sp) => PushoverSettings(sp.getRequiredService<SecretStore>()),
    )
    ..addSingleton<EmbeddingSettings>(
      (sp) => EmbeddingSettings(
        keyValueStore: kv,
        manager: sp.getRequiredService<ConfiguredAgentsManager>(),
      ),
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
    // nothing pops it. On compact widths its header carries an explicit back
    // button; on wide layouts the settings sidebar is the way out and the
    // back control is dropped.
    testWidgets('Logs & diagnostics goes back to settings home (compact)', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final location in [
        '/settings/logging',
        '/settings/logging/prompts',
      ]) {
        await tester.pumpWidget(_app(services, initialLocation: location));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHomeScreen), findsNothing, reason: location);

        await tester.tap(find.byType(SettingsBackButton));
        await tester.pumpAndSettle();

        expect(
          find.byType(SettingsHomeScreen),
          findsOneWidget,
          reason: location,
        );
      }
    });

    testWidgets('wide: the sidebar leaves Logs & diagnostics', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final location in [
        '/settings/logging',
        '/settings/logging/prompts',
      ]) {
        await tester.pumpWidget(_app(services, initialLocation: location));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsBackButton), findsNothing, reason: location);
        expect(find.byType(SettingsSidebar), findsOneWidget, reason: location);

        await tester.tap(find.text('Profile'));
        await tester.pumpAndSettle();
        expect(
          find.byType(ProfileSettingsScreen),
          findsOneWidget,
          reason: location,
        );
      }
    });

    // Appearance and Profile are pushed sub-pages of Settings, so on compact
    // widths back is a real pop; the shared header still spells the
    // destination out.
    for (final (label, path) in [
      ('Appearance', '/settings/appearance'),
      ('Profile', '/settings/profile'),
    ]) {
      testWidgets('$label opens from Settings and comes back', (tester) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        tester.view.physicalSize = const Size(420, 1400);
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

    // On wide layouts Settings is master-detail: the persistent sidebar
    // opens sections beside itself, the home route is a placeholder, and no
    // back control is shown anywhere — the sidebar is the navigation.
    testWidgets('wide: the sidebar opens sections beside a placeholder home', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();
      expect(find.text('Select a settings section.'), findsOneWidget);

      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.byType(AppearanceSettingsScreen), findsOneWidget);
      expect(find.byType(SettingsSidebar), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileSettingsScreen), findsOneWidget);
    });

    // The reset row moved off the Settings home into General's danger zone,
    // so the destructive action sits behind one deliberate step.
    testWidgets('General: reset lives behind the danger zone', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();
      expect(find.text('Reset app data'), findsNothing);

      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset app data'));
      await tester.pumpAndSettle();
      expect(find.text('Reset app data?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Erase everything'), findsNothing);
    });

    // Revisited onboarding is hosted inside Settings — the /onboarding guard
    // sends configured users to /chats — and its actions route to the
    // Settings-hosted flows.
    testWidgets('General: onboarding revisits inside Settings', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      // 600, not 420: the add-agent wizard's step indicator overflows at
      // phone widths (a pre-existing wizard layout issue, not what this
      // test is about).
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/general'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start onboarding'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);

      await tester.tap(find.text('API agent'));
      await tester.pumpAndSettle();
      expect(find.byType(AddAgentWizard), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
    });

    // The Memory page is the UI over EmbeddingSettings: only models on
    // OpenAI-compatible sources are offered, and the choice round-trips
    // through the persisted setting.
    testWidgets('Memory picks an embedding model and persists it', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(
        const ModelSourceConfig(
          id: 'source-openai',
          providerType: ProviderType.openAiCompatible,
          displayName: 'Local server',
          endpoint: 'http://localhost:1234/v1',
        ),
      );
      await manager.saveModel(
        const ModelConfig(
          id: 'model-embed',
          sourceId: 'source-openai',
          modelId: 'text-embedding-3-small',
          displayName: 'Embed Small',
        ),
      );
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/memory'),
      );
      await tester.pumpAndSettle();

      // The seeded chat model rides a localLlama source, so only the
      // OpenAI-compatible entry is offered beside the default.
      expect(find.text('Keyword matching'), findsOneWidget);
      expect(find.text('Embed Small'), findsOneWidget);
      expect(find.text('Test Agent'), findsNothing);

      final settings = services.getRequiredService<EmbeddingSettings>();
      await tester.tap(find.text('Embed Small'));
      await tester.pumpAndSettle();
      expect(await settings.selectedModelId, 'model-embed');

      await tester.tap(find.text('Keyword matching'));
      await tester.pumpAndSettle();
      expect(await settings.selectedModelId, isNull);
    });

    testWidgets('Memory without an eligible source points at sources', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/memory'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open model sources'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsSectionShell), findsOneWidget);
      expect(find.text('Sources'), findsWidgets);
    });

    // Storage measures both native byte stores — the picked-file copies and
    // the download service's directories — and its delete clears them while
    // the model's configuration survives.
    testWidgets('Storage measures a local model and deletes its bytes', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      // A URL-backed model's bytes live in the download store; a picked-file
      // copy for it would be pruned at startup as an orphan.
      io.File('${storeRoot.path}/local_llama/model-1/weights.gguf')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(2048, 7));
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/storage'),
      );
      await tester.pumpAndSettle();

      expect(find.text('fake-model'), findsOneWidget);
      expect(find.text('2.0 KB · downloaded'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete files'));
      await tester.pumpAndSettle();

      expect(
        io.Directory('${storeRoot.path}/local_models/model-1').existsSync(),
        isFalse,
      );
      expect(
        io.Directory('${storeRoot.path}/local_llama/model-1').existsSync(),
        isFalse,
      );
      expect(find.text('Nothing downloaded yet'), findsOneWidget);
      expect(
        await services
            .getRequiredService<ConfiguredAgentsManager>()
            .sources
            .getModel('model-1'),
        isNotNull,
        reason: 'deleting bytes must keep the configuration',
      );
    });

    // The auto-title toggle drives ChatSettings, which the title
    // summarizer's client callback consults live.
    testWidgets('General: the auto-title toggle persists', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/general'),
      );
      await tester.pumpAndSettle();

      final chat = services.getRequiredService<ChatSettings>();
      expect(chat.autoTitleEnabled, isTrue);

      await tester.tap(find.text('Auto-title conversations'));
      await tester.pumpAndSettle();
      expect(chat.autoTitleEnabled, isFalse);

      // Survives a reload from storage — the persisted value, not just the
      // in-memory flag, flipped.
      await chat.load();
      expect(chat.autoTitleEnabled, isFalse);
    });

    testWidgets('Notifications shows status and opens the credentials '
        'dialog', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/notifications'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Add an application token'), findsOneWidget);

      await tester.tap(find.text('Pushover credentials'));
      await tester.pumpAndSettle();
      expect(find.text('Pushover notifications'), findsOneWidget);
      expect(find.text('Application token'), findsOneWidget);
      expect(find.text('User key'), findsOneWidget);
    });

    testWidgets('Profile computes lifetime stats locally', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      services.getRequiredService<UsageStore>().recordAttributed(
        ChatUsageRecord(
          timestamp: DateTime.now(),
          modelId: 'model-1',
          sourceId: 'source-1',
          provider: 'local_llama',
          inputTokenCount: 100,
          outputTokenCount: 50,
        ),
        agentId: 'agent-1',
      );
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/profile'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Lifetime tokens'), findsOneWidget);
      expect(find.text('150'), findsOneWidget);
      expect(find.text('Model calls'), findsOneWidget);
      expect(find.text('Days active'), findsOneWidget);
    });

    // Hardware reports real measurements: the CPU facts from the platform
    // and the live memory sample from the llama runtime's monitor.
    testWidgets('Hardware reports CPU facts and live memory', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/hardware'),
      );
      // Not pumpAndSettle: the page keeps a periodic refresh timer that
      // would never settle. First let the router's async redirect mount the
      // page and its transition play, then give the real subprocess reads
      // (sysctl, df) behind the facts real-time windows until they land.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 20 && !tester.any(find.text('CPU')); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }

      // The macOS test runner measures for real: CPU facts, a RAM card
      // with a free-space line, and a disk card.
      expect(find.text('CPU'), findsOneWidget);
      expect(
        find.textContaining('${io.Platform.numberOfProcessors} cores'),
        findsOneWidget,
      );
      expect(find.text('RAM'), findsOneWidget);
      expect(find.text('Disk'), findsOneWidget);
      expect(find.textContaining('free'), findsWidgets);
      expect(
        find.text('Live readings are not available on this platform.'),
        findsNothing,
      );
    });

    testWidgets('About reports the running version and opens licenses', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();
      // The home row already names the version once package info is loaded.
      expect(find.text('Version 9.9.9 (42)'), findsOneWidget);

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.text('9.9.9 (42)'), findsOneWidget);
      expect(find.text('dev.example.agents'), findsOneWidget);

      await tester.tap(find.text('Open source licenses'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LicensePage), findsOneWidget);
    });

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

      // The Agent Center's tabs are the sidebar's own rows on this width.
      await tester.tap(find.text('Agents'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomeScreen), findsNothing);
      final shell = tester.element(find.byType(AgentCenterShell));

      await tester.tap(find.text('Models'));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byType(AgentCenterShell)),
        same(shell),
        reason: 'switching tabs must not remount the section',
      );

      // Wide layouts drop the back control; leaving is a sidebar navigation.
      expect(find.byType(SettingsBackButton), findsNothing);
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentCenterShell), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // The wizard's step chips share the width with their labels; on a phone
    // inside the Agent Center the three-step API flow used to overflow.
    testWidgets('add-agent wizard step indicator fits a compact width', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/add?type=api'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AddAgentWizard), findsOneWidget);
      expect(find.text('Add agent — Provider'), findsOneWidget);
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

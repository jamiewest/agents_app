import 'dart:io' as io;

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/local_model_store_io.dart';
import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/navigation/app_bootstrap.dart';
import 'package:agents_app/navigation/app_router.dart';
import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_app/ui/screens/agent_center_overview_screen.dart';
import 'package:agents_app/ui/screens/agent_center_screen.dart';
import 'package:agents_app/ui/screens/agent_detail_screen.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
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

/// The name input of an editor form.
///
/// Editor labels are siblings of their input rather than
/// `InputDecoration` labels, so they are reached through the shared field
/// wrapper.
final Finder _nameField = find.descendant(
  of: find.widgetWithText(ConfiguredAgentsFormField, 'Name'),
  matching: find.byType(TextFormField),
);

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

      // The page header's hamburger opens the drawer, which lists the
      // top-level destinations above the conversations panel.
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('AGENT TEAMS'), findsOneWidget);

      // Picking a destination closes the drawer and switches branch.
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.textContaining('No tasks yet'), findsOneWidget);
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
      expect(find.text('Agent Center'), findsOneWidget);
    });

    testWidgets('settings card opens the Agent Center on Agents', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();
      // The card summarizes state rather than naming the destination.
      expect(find.textContaining('1 agent'), findsOneWidget);

      await tester.tap(find.text('Agent Center'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentCenterScreen), findsOneWidget);
      expect(find.text('Test Agent'), findsOneWidget);
    });

    testWidgets('settings card flags agents whose model is missing', (
      tester,
    ) async {
      final services = _buildServices();
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await _seedUsableAgent(services);
      // A second agent pointing at a model that was never created.
      await manager.saveAgent(
        const SavedAgentConfig(
          id: 'agent-2',
          name: 'Broken',
          modelId: 'model-gone',
        ),
      );

      await tester.pumpWidget(_app(services, initialLocation: '/settings'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 need setup'), findsOneWidget);
    });

    testWidgets('each Agent Center section deep-links to its own route', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      for (final (location, expected) in [
        ('/settings/agents', 'Test Agent'),
        ('/settings/agents/models', 'fake-model'),
        ('/settings/agents/sources', 'Local'),
      ]) {
        await tester.pumpWidget(_app(services, initialLocation: location));
        await tester.pumpAndSettle();
        expect(
          find.byType(AgentCenterScreen),
          findsOneWidget,
          reason: location,
        );
        expect(find.text(expected), findsWidgets, reason: location);
      }
    });

    testWidgets('edit and create routes open the matching form', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/edit/agent-1'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditor), findsOneWidget);
      expect(
        tester.widget<AgentEditor>(find.byType(AgentEditor)).initial?.id,
        'agent-1',
      );

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/sources/new'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SourceEditor), findsOneWidget);
      expect(
        tester.widget<SourceEditor>(find.byType(SourceEditor)).initial,
        isNull,
      );
    });

    // Below the master-detail width the editor is a route, not a pane, so
    // every one of these interactions runs through go_router. This is the
    // primary layout on a phone, and it cannot be reached from a harness
    // that hosts the screen without a router.
    group('Agent Center on a compact layout', () {
      // Tall enough that the whole agent form, Save included, is on screen.
      const compact = Size(420, 2600);

      Future<void> openEditor(WidgetTester tester, ServiceProvider services) {
        tester.view.physicalSize = compact;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        return tester
            .pumpWidget(
              _app(services, initialLocation: '/settings/agents/edit/agent-1'),
            )
            .then((_) => tester.pumpAndSettle());
      }

      testWidgets('selecting an agent opens its detail page', (tester) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        tester.view.physicalSize = compact;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _app(services, initialLocation: '/settings/agents'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AgentDetailScreen), findsNothing);

        await tester.tap(find.text('Test Agent'));
        await tester.pumpAndSettle();

        expect(find.byType(AgentDetailScreen), findsOneWidget);
      });

      testWidgets('saving returns to the list with the change persisted', (
        tester,
      ) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        await openEditor(tester, services);

        await tester.enterText(_nameField, 'Renamed');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final saved = await services
            .getRequiredService<ConfiguredAgentsManager>()
            .agents
            .getAgent('agent-1');
        expect(saved?.name, 'Renamed');
        expect(find.byType(AgentEditor), findsNothing);
        expect(find.text('Renamed'), findsOneWidget);
      });

      testWidgets('backing out of a dirty form asks before discarding', (
        tester,
      ) async {
        // PopScope plus context.go is the pattern most likely to be subtly
        // wrong, and it is the guard protecting unsaved work.
        final services = _buildServices();
        await _seedUsableAgent(services);
        await openEditor(tester, services);

        await tester.enterText(_nameField, 'Changed');
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsOneWidget);

        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(find.byType(AgentEditor), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard'));
        await tester.pumpAndSettle();

        expect(find.byType(AgentEditor), findsNothing);
        expect(find.text('Test Agent'), findsOneWidget);
      });

      testWidgets('backing out of an untouched form asks nothing', (
        tester,
      ) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        await openEditor(tester, services);

        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.byType(AgentEditor), findsNothing);
        expect(find.text('Test Agent'), findsOneWidget);
      });

      testWidgets('the section switcher navigates between catalogs', (
        tester,
      ) async {
        final services = _buildServices();
        await _seedUsableAgent(services);
        tester.view.physicalSize = compact;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _app(services, initialLocation: '/settings/agents'),
        );
        await tester.pumpAndSettle();

        // The four-tab nav scrolls horizontally when it does not fit, so
        // bring the target segment on screen before tapping it.
        await tester.ensureVisible(find.text('Sources'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        expect(find.text('Local'), findsOneWidget);

        await tester.ensureVisible(find.text('Models'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Models'));
        await tester.pumpAndSettle();
        expect(find.text('fake-model'), findsOneWidget);
      });
    });

    testWidgets('wide layouts guard the route pop too', (tester) async {
      // The editor is a pane here, not a page, but the URL is still an edit
      // route — so browser or OS back must not discard the form silently.
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/edit/agent-1'),
      );
      await tester.pumpAndSettle();
      // Both panes share the screen, so this is genuinely the wide layout.
      expect(find.byType(AgentEditor), findsOneWidget);
      expect(find.byType(ListView), findsWidgets);

      await tester.enterText(_nameField, 'Changed');
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditor), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentEditor), findsNothing);
      expect(find.text('Test Agent'), findsOneWidget);
    });

    testWidgets('tapping an agent opens its detail page, Edit opens the form', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentDetailScreen), findsOneWidget);
      // The list is gone — this is a page, not an inline pane.
      expect(find.byType(AgentCenterScreen), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditor), findsOneWidget);
    });

    testWidgets('a delegate link opens that agent, and back returns', (
      tester,
    ) async {
      final services = _buildServices();
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await _seedUsableAgent(services);
      // A second agent, delegated to by the first.
      await manager.saveAgent(
        const SavedAgentConfig(
          id: 'agent-2',
          name: 'Delegate Agent',
          modelId: 'model-1',
        ),
      );
      await manager.saveAgent(
        _agent.copyWith(
          delegations: const [AgentDelegationConfig(agentId: 'agent-2')],
        ),
      );
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/view/agent-1'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delegate Agent'));
      await tester.pumpAndSettle();
      expect(find.text('Delegate Agent'), findsWidgets);

      // Back returns to the first agent's detail, not out to the list.
      final backButton = find.byTooltip('Back');
      if (backButton.evaluate().isNotEmpty) {
        await tester.tap(backButton.first);
        await tester.pumpAndSettle();
        expect(find.byType(AgentDetailScreen), findsOneWidget);
      }
    });

    testWidgets('a models row still opens the editor directly', (tester) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/models'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('fake-model'));
      await tester.pumpAndSettle();

      // No detail page for models — straight to the editor.
      expect(find.byType(AgentDetailScreen), findsNothing);
      expect(find.byType(ModelEditor), findsOneWidget);
    });

    testWidgets('the Overview tab is reachable and navigates back', (
      tester,
    ) async {
      final services = _buildServices();
      await _seedUsableAgent(services);
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentCenterOverviewScreen), findsOneWidget);
      expect(find.text('Active agents'), findsOneWidget);

      // The nav on Overview routes back to the catalogs.
      await tester.tap(find.text('Agents'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentCenterScreen), findsOneWidget);
      expect(find.text('Test Agent'), findsOneWidget);
    });

    testWidgets('the setup wizard stays reachable from the Agent Center', (
      tester,
    ) async {
      // A section literal must never shadow this route.
      final services = _buildServices();
      await _seedUsableAgent(services);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/add'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AddAgentWizard), findsOneWidget);
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

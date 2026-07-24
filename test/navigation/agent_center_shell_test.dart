// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/local_model_store_io.dart';
import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/navigation/app_bootstrap.dart';
import 'package:agents_app/navigation/app_router.dart';
import 'package:agents_app/ui/screens/agent_center_nav.dart';
import 'package:agents_app/ui/screens/agent_catalog_view.dart';
import 'package:agents_app/ui/screens/agent_center_shell.dart';
import 'package:agents_app/ui/screens/agent_detail_screen.dart';
import 'package:agents_app/ui/screens/agent_editor_page.dart';
import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
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
  final services = ServiceCollection()
    ..addSingleton<ThemeSettings>((_) => ThemeSettings(InMemoryKeyValueStore()))
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

Future<void> _seed(ServiceProvider services) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_source);
  await manager.saveModel(_model);
  await manager.saveAgent(_agent);
}

Widget _app(ServiceProvider services, {required String initialLocation}) =>
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

  late io.Directory storeRoot;
  setUp(() {
    storeRoot = io.Directory.systemTemp.createTempSync('shell_test');
    debugLocalModelStoreRoot = storeRoot;
  });
  tearDown(() {
    debugLocalModelStoreRoot = null;
    storeRoot.deleteSync(recursive: true);
  });

  group('Agent Center shell routing (skeleton)', () {
    testWidgets('each tab path lands on the right branch', (tester) async {
      final services = _buildServices();
      await _seed(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final (location, kind) in [
        ('/settings/agents/overview', null),
        ('/settings/agents', AgentCenterTab.agents),
        ('/settings/agents/models', AgentCenterTab.models),
        ('/settings/agents/sources', AgentCenterTab.sources),
      ]) {
        await tester.pumpWidget(_app(services, initialLocation: location));
        await tester.pumpAndSettle();
        expect(find.byType(AgentCenterShell), findsOneWidget, reason: location);
        if (kind == null) {
          expect(find.text('Active agents'), findsOneWidget, reason: location);
        } else {
          final view = tester.widget<AgentCatalogView>(
            find.byType(AgentCatalogView),
          );
          expect(view.kind, kind, reason: location);
        }
      }
    });

    testWidgets('switching tabs keeps one shell mounted and swaps content', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AgentCatalogView>(find.byType(AgentCatalogView)).kind,
        AgentCenterTab.agents,
      );

      await tester.tap(find.text('Models'));
      await tester.pumpAndSettle();

      // The very same shell instance persists across the switch, and only
      // the content changed.
      expect(find.byType(AgentCenterShell), findsOneWidget);
      expect(find.byType(AgentCenterNav), findsOneWidget);
      expect(
        tester.widget<AgentCatalogView>(find.byType(AgentCatalogView)).kind,
        AgentCenterTab.models,
      );
    });

    testWidgets('pushing a detail keeps the nav visible', (tester) async {
      final services = _buildServices();
      await _seed(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/view/agent-1'),
      );
      await tester.pumpAndSettle();

      // Detail content shows in the content area; the persistent nav is
      // still there beside it.
      expect(find.byType(AgentDetailScreen), findsOneWidget);
      expect(find.byType(AgentCenterNav), findsOneWidget);
    });

    testWidgets('branch stacks are preserved across tab switches', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(services, initialLocation: '/settings/agents/view/agent-1'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentDetailScreen), findsOneWidget);

      // Leave to Models and come back — the pushed detail should still be on
      // the agents branch stack.
      await tester.tap(find.text('Models'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agents'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentDetailScreen), findsOneWidget);
    });
  });

  group('Agent Center flows', () {
    Future<void> pumpAt(
      WidgetTester tester,
      ServiceProvider services,
      String location, {
      Size size = const Size(1200, 1600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(services, initialLocation: location));
      await tester.pumpAndSettle();
    }

    testWidgets('the settings card opens the Agent Center on Agents', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(tester, services, '/settings');
      await tester.tap(find.text('Agent Center'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentCatalogView), findsOneWidget);
      expect(find.text('Test Agent'), findsOneWidget);
    });

    testWidgets('the setup wizard stays reachable', (tester) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(tester, services, '/settings/agents/add');

      expect(find.byType(AddAgentWizard), findsOneWidget);
    });

    testWidgets('tapping an agent card opens its detail, Edit opens the form', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(tester, services, '/settings/agents');
      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentDetailScreen), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditorPage), findsOneWidget);
    });

    testWidgets('editing an agent from its route saves and returns', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(
        tester,
        services,
        '/settings/agents/edit/agent-1',
        size: const Size(1200, 2600),
      );
      expect(find.byType(AgentEditorPage), findsOneWidget);

      final name = find.descendant(
        of: find.widgetWithText(ConfiguredAgentsFormField, 'Name'),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(name, 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await services
          .getRequiredService<ConfiguredAgentsManager>()
          .agents
          .getAgent('agent-1');
      expect(saved?.name, 'Renamed');
      // Back on the catalog.
      expect(find.byType(AgentCatalogView), findsOneWidget);
      expect(find.text('Renamed'), findsOneWidget);
    });

    testWidgets('backing out of a dirty editor asks first', (tester) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(
        tester,
        services,
        '/settings/agents/edit/agent-1',
        size: const Size(1200, 2600),
      );
      final name = find.descendant(
        of: find.widgetWithText(ConfiguredAgentsFormField, 'Name'),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(name, 'Changed');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditorPage), findsOneWidget);
    });

    testWidgets('a models card opens the model editor', (tester) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(tester, services, '/settings/agents/models');
      await tester.tap(find.text('fake-model'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentEditorPage), findsOneWidget);
      expect(find.byType(ModelEditor), findsOneWidget);
    });

    testWidgets('deleting a model offers a cascade', (tester) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(tester, services, '/settings/agents/models');
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      // The model is in use by the agent, so the manager offers a cascade.
      expect(find.text('Delete anyway'), findsOneWidget);
      await tester.tap(find.text('Delete anyway'));
      await tester.pumpAndSettle();

      expect(
        await services
            .getRequiredService<ConfiguredAgentsManager>()
            .sources
            .listModels(),
        isEmpty,
      );
    });

    testWidgets('compact: the nav persists while a detail pushes below', (
      tester,
    ) async {
      // The phone path: horizontal tabs stay put, and tapping an agent
      // pushes its detail into the content area beneath them.
      final services = _buildServices();
      await _seed(services);

      await pumpAt(
        tester,
        services,
        '/settings/agents',
        size: const Size(420, 1800),
      );
      expect(find.byType(AgentCenterNav), findsOneWidget);

      await tester.tap(find.text('Test Agent'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentDetailScreen), findsOneWidget);
      // The tabs are still mounted above the pushed detail.
      expect(find.byType(AgentCenterNav), findsOneWidget);
    });

    testWidgets('compact: switching tabs keeps the shell mounted', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);

      await pumpAt(
        tester,
        services,
        '/settings/agents',
        size: const Size(420, 1800),
      );
      // The compact nav is a horizontal segmented control that scrolls when
      // it does not fit, so bring the target segment on screen first.
      expect(find.byType(SegmentedButton<AgentCenterTab>), findsOneWidget);

      await tester.ensureVisible(find.text('Models'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Models'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentCenterShell), findsOneWidget);
      expect(
        tester.widget<AgentCatalogView>(find.byType(AgentCatalogView)).kind,
        AgentCenterTab.models,
      );
    });

    testWidgets('agent cards show run stats once there is history', (
      tester,
    ) async {
      final services = _buildServices();
      await _seed(services);
      final runs = services.getRequiredService<AgentRunTelemetryStore>();
      await (await runs.begin(
        agentId: 'agent-1',
        agentName: 'Test Agent',
        origin: AgentRunOrigin.chat,
      )).succeed();

      await pumpAt(tester, services, '/settings/agents');

      // The card carries a metric row, not just a name.
      expect(find.text('Runs'), findsWidgets);
      expect(find.text('Success'), findsOneWidget);
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

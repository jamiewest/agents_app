// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/ui/screens/agent_detail_screen.dart';
import 'package:agents_app/ui/widgets/charts.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.openAiCompatible,
  displayName: 'My provider',
);
const _model = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'gpt-test',
  displayName: 'Test model',
);
const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Researcher',
  modelId: 'model-1',
  description: 'Finds things',
  instructions: 'Be thorough.',
  access: AgentAccessConfig(enableWebSearch: true, enableShell: false),
  delegations: [AgentDelegationConfig(agentId: 'agent-2')],
);
const _delegate = SavedAgentConfig(
  id: 'agent-2',
  name: 'Writer',
  modelId: 'model-1',
);

ServiceProvider _services() {
  final services = ServiceCollection()
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
    );
  return services.buildServiceProvider();
}

ConfiguredAgentsManager _manager(ServiceProvider services) =>
    services.getRequiredService<ConfiguredAgentsManager>();

Future<void> _seed(ServiceProvider services) async {
  final manager = _manager(services);
  await manager.saveSource(_source);
  await manager.saveModel(_model);
  // The delegate must exist before the agent that delegates to it.
  await manager.saveAgent(_delegate);
  await manager.saveAgent(_agent);
}

/// Records runs for [agentId] just now.
Future<void> _runsFor(
  ServiceProvider services,
  String agentId, {
  int succeeded = 0,
}) async {
  final runs = services.getRequiredService<AgentRunTelemetryStore>();
  for (var i = 0; i < succeeded; i++) {
    await (await runs.begin(
      agentId: agentId,
      agentName: agentId,
      origin: AgentRunOrigin.chat,
    )).succeed();
  }
}

Widget _host(ServiceProvider services, {String agentId = 'agent-1'}) =>
    MaterialApp(
      home: AgentDetailScreen(
        services: services,
        agentId: agentId,
        now: () => DateTime(2026, 7, 23, 12),
      ),
    );

void main() {
  group('AgentDetailScreen', () {
    testWidgets('shows identity, model, and source', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(const Size(900, 1600), _host(services));

      expect(find.text('Researcher'), findsWidgets);
      expect(find.text('Finds things'), findsOneWidget);
      expect(find.text('Test model'), findsOneWidget);
      expect(find.text('My provider'), findsOneWidget);
    });

    testWidgets('shows enabled tools and hides disabled ones', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(const Size(900, 1600), _host(services));

      expect(find.text('Web search'), findsOneWidget);
      expect(find.text('Shell'), findsNothing);
    });

    testWidgets('resolves delegate names', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(const Size(900, 1600), _host(services));

      expect(find.text('Delegates'), findsOneWidget);
      expect(find.text('Writer'), findsOneWidget);
    });

    testWidgets('per-agent charts appear with enough of this agent\'s runs', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);
      await _runsFor(services, 'agent-1', succeeded: 5);
      // Another agent's runs must not pull this agent over the threshold.
      await _runsFor(services, 'agent-2', succeeded: 20);

      await tester.pumpAt(const Size(900, 2200), _host(services));

      expect(find.byType(StackedBarChart), findsOneWidget);
      // Only this agent's 5 runs count.
      expect(find.textContaining('5/5 succeeded'), findsOneWidget);
    });

    testWidgets('a deleted agent shows a gentle empty state', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        const Size(900, 1200),
        _host(services, agentId: 'ghost'),
      );

      expect(find.text('This agent no longer exists.'), findsOneWidget);
    });

    testWidgets('does not show the fleet-only active-agents KPI', (
      tester,
    ) async {
      // "Active agents" is meaningless on a single-agent page (it is always
      // one). The Runs and Success tiles carry the per-agent numbers.
      final services = _services();
      await _seed(services);
      await _runsFor(services, 'agent-1', succeeded: 2);

      await tester.pumpAt(const Size(900, 1800), _host(services));

      expect(find.text('Active agents'), findsNothing);
      expect(find.text('Runs'), findsWidgets);
      expect(find.text('Success rate'), findsOneWidget);
    });

    testWidgets('has an Edit action', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(const Size(900, 1600), _host(services));

      expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
    });
  });
}

extension on WidgetTester {
  Future<void> pumpAt(Size size, Widget widget) async {
    view.physicalSize = size;
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
    await pumpWidget(widget);
    await pumpAndSettle();
  }
}

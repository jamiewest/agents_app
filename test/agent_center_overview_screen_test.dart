// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/ui/screens/agent_center_overview_screen.dart';
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
);

ServiceProvider _services() {
  final records = InMemoryRecordStore();
  final services = ServiceCollection()
    ..addRecordStore(recordStore: (_) => records)
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

Future<void> _seedConfig(ServiceProvider services, {bool key = true}) async {
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_source, apiKey: key ? 'sk-test' : null);
  await manager.saveModel(_model);
  await manager.saveAgent(_agent);
}

/// Records [count] finished runs for the seeded agent, all just now.
Future<void> _seedRuns(
  ServiceProvider services, {
  int succeeded = 0,
  int failed = 0,
}) async {
  final runs = services.getRequiredService<AgentRunTelemetryStore>();
  for (var i = 0; i < succeeded; i++) {
    await (await runs.begin(
      agentId: 'agent-1',
      agentName: 'Researcher',
      origin: AgentRunOrigin.chat,
      modelName: 'Test model',
      conversationId: 'conv-$i',
    )).succeed();
  }
  for (var i = 0; i < failed; i++) {
    await (await runs.begin(
      agentId: 'agent-1',
      agentName: 'Researcher',
      origin: AgentRunOrigin.chat,
    )).fail();
  }
}

Widget _host(ServiceProvider services) => MaterialApp(
  home: Scaffold(
    body: AgentCenterOverviewBody(
      services: services,
      now: () => DateTime(2026, 7, 23, 12),
    ),
  ),
);

void main() {
  group('AgentCenterOverviewBody', () {
    testWidgets('shows KPI cards', (tester) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 4, failed: 1);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Active agents'), findsOneWidget);
      expect(find.text('Runs'), findsWidgets);
      expect(find.text('Success rate'), findsOneWidget);
      // 4 of 5 completed succeeded.
      expect(find.text('80%'), findsOneWidget);
    });

    testWidgets('charts appear once there is enough history', (tester) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 5);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.byType(StackedBarChart), findsOneWidget);
      expect(find.byType(Sparkline), findsOneWidget);
    });

    testWidgets('low data leads with the not-enough-data panel', (
      tester,
    ) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 1);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.byType(StackedBarChart), findsNothing);
      expect(find.textContaining('Not enough runs'), findsOneWidget);
      // KPIs still show.
      expect(find.text('Active agents'), findsOneWidget);
    });

    testWidgets('flags an agent whose key is missing', (tester) async {
      final services = _services();
      await _seedConfig(services, key: false);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Needs setup'), findsOneWidget);
      expect(find.text('Missing API key'), findsOneWidget);
    });

    testWidgets('workload lists the agent that ran', (tester) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 3);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Workload by agent'), findsOneWidget);
      expect(find.text('Researcher'), findsWidgets);
    });

    testWidgets('recent runs list the newest work', (tester) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 2);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      expect(find.text('Recent runs'), findsOneWidget);
      expect(find.textContaining('Chat'), findsWidgets);
    });

    testWidgets('changing the range reloads the dashboard', (tester) async {
      final services = _services();
      await _seedConfig(services);
      await _seedRuns(services, succeeded: 4);

      await tester.pumpWidget(_host(services));
      await tester.pumpAndSettle();

      // Switch to 24h; the runs are all "now" so they stay in range.
      await tester.tap(find.text('24h'));
      await tester.pumpAndSettle();

      expect(find.text('Active agents'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

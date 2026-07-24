// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_task_store.dart';
import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/domain/agent_task.dart';
import 'package:agents_app/ui/screens/tasks_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Researcher',
  modelId: 'model-1',
);

Future<(ServiceProvider, AgentTaskStore)> _setup() async {
  final records = InMemoryRecordStore();
  final services = (ServiceCollection()
        ..addRecordStore(recordStore: (_) => records)
        ..addConfiguredAgents(
          keyValueStore: (_) => InMemoryKeyValueStore(),
          secretStore: (_) => InMemorySecretStore(),
        ))
      .buildServiceProvider();
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(
    const ModelSourceConfig(
      id: 'source-1',
      providerType: ProviderType.openAiCompatible,
      displayName: 'Prov',
    ),
  );
  await manager.saveModel(
    const ModelConfig(id: 'model-1', sourceId: 'source-1', modelId: 'gpt'),
  );
  await manager.saveAgent(_agent);
  return (services, AgentTaskStore(records));
}

AgentTask _task() => AgentTask(
  id: 't1',
  title: 'Morning digest',
  prompt: 'Summarize the news.',
  agentId: 'agent-1',
  status: AgentTaskStatus.scheduled,
  intervalMinutes: 60,
  nextRunAt: DateTime.utc(2026, 7, 24, 9),
  createdAt: DateTime.utc(2026, 7, 1),
);

Widget _host(ServiceProvider services) => MaterialApp(
  home: TasksScreen(
    services: services,
    scheduler: TaskSchedulerService(services),
  ),
);

void main() {
  testWidgets('the task menu offers Edit and pre-fills the dialog', (
    tester,
  ) async {
    final (services, store) = await _setup();
    await store.save(_task());

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    expect(find.text('Morning digest'), findsOneWidget);

    await tester.tap(find.byTooltip('Task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // The dialog opens pre-filled with the task's values.
    expect(find.text('Edit task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Morning digest'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Summarize the news.'), findsOneWidget);
  });

  testWidgets('saving an edit keeps the id and updates the fields', (
    tester,
  ) async {
    final (services, store) = await _setup();
    await store.save(_task());

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Morning digest'),
      'Evening digest',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = (await store.get('t1'))!;
    // Same task — id and conversation preserved, editable fields changed.
    expect(saved.id, 't1');
    expect(saved.taskConversationId, 'task-t1');
    expect(saved.title, 'Evening digest');
    expect(saved.prompt, 'Summarize the news.');
    expect(saved.intervalMinutes, 60);
    expect(saved.createdAt, DateTime.utc(2026, 7, 1));
  });

  testWidgets('editing a running task is disabled', (tester) async {
    final (services, store) = await _setup();
    await store.save(
      AgentTask(
        id: 't1',
        title: 'Busy',
        prompt: 'p',
        agentId: 'agent-1',
        status: AgentTaskStatus.running,
        createdAt: DateTime.utc(2026, 7, 1),
      ),
    );

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Task actions'));
    await tester.pumpAndSettle();

    final edit = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Edit'),
    );
    expect(edit.enabled, isFalse);
  });
}

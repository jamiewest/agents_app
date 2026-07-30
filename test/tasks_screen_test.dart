// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/task_detail_screen.dart';
import 'package:agents_app/ui/screens/tasks_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Researcher',
  modelId: 'model-1',
);

Future<(ServiceProvider, AgentTaskStore)> _setup() async {
  final records = InMemoryRecordStore();
  final services =
      (ServiceCollection()
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
  schedule: const IntervalSchedule(60),
  nextRunAt: DateTime.utc(2026, 7, 24, 9),
  createdAt: DateTime.utc(2026, 7, 1),
);

/// Hosts the Tasks branch under a real router so task cards can navigate
/// to the detail page, mirroring the app's route layout.
Widget _host(ServiceProvider services, {String initialLocation = '/tasks'}) {
  final scheduler = TaskSchedulerService(services);
  return MaterialApp.router(
    routerConfig: GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/tasks',
          builder: (context, state) =>
              TasksScreen(services: services, scheduler: scheduler),
          routes: [
            GoRoute(
              path: 't/:id',
              builder: (context, state) => TaskDetailScreen(
                services: services,
                scheduler: scheduler,
                taskId: state.pathParameters['id']!,
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/chats/c/:conversationId',
          builder: (context, state) => const Placeholder(),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('a saved task renders as a card that opens its detail page', (
    tester,
  ) async {
    final (services, store) = await _setup();
    await store.save(_task());

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    expect(find.text('Morning digest'), findsOneWidget);

    await tester.tap(find.text('Morning digest'));
    await tester.pumpAndSettle();

    // The detail page shows the task's instructions, schedule, and status.
    expect(find.text('Instructions'), findsOneWidget);
    expect(find.text('Summarize the news.'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('Edit pre-fills the dialog and saving keeps the id', (
    tester,
  ) async {
    final (services, store) = await _setup();
    await store.save(_task());

    await tester.pumpWidget(_host(services, initialLocation: '/tasks/t/t1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    // The dialog opens pre-filled with the task's values.
    expect(find.text('Edit scheduled task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Morning digest'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Summarize the news.'),
      findsOneWidget,
    );

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
    expect(saved.schedule, const IntervalSchedule(60));
    expect(saved.createdAt, DateTime.utc(2026, 7, 1));
  });

  testWidgets('edit and run-now are disabled while the task is running', (
    tester,
  ) async {
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

    await tester.pumpWidget(_host(services, initialLocation: '/tasks/t/t1'));
    await tester.pumpAndSettle();

    final edit = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Edit'),
        matching: find.byType(IconButton),
      ),
    );
    expect(edit.onPressed, isNull);
    final runNow = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run now'),
    );
    expect(runNow.onPressed, isNull);
  });

  testWidgets('a template pre-fills the create dialog', (tester) async {
    final (services, _) = await _setup();

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();

    // No tasks yet: the empty state shows above the template gallery.
    expect(find.text('No scheduled tasks yet.'), findsOneWidget);

    await tester.tap(find.text('Weekly review'));
    await tester.pumpAndSettle();

    expect(find.text('Create scheduled task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Weekly review'), findsOneWidget);
  });

  testWidgets('the editor can schedule the first Tuesday of every month', (
    tester,
  ) async {
    final (services, store) = await _setup();

    await tester.pumpWidget(_host(services));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Daily briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily briefing'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Every day'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monthly on a weekday…').last);
    await tester.pumpAndSettle();

    // The follow-up pickers appear with their defaults visible.
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Monday'), findsOneWidget);
    expect(find.text('9:00 AM'), findsOneWidget);

    await tester.tap(find.text('Monday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tuesday').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The first Tuesday of every month at 9:00 AM while the app '
        'is open.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final saved = (await store.listDue(DateTime.utc(2100))).single;
    expect(
      saved.schedule,
      const MonthlyWeekdaySchedule(week: 1, weekday: DateTime.tuesday),
    );
    // The first run waits for the next occurrence instead of firing now:
    // a first-of-the-month Tuesday at 9:00, in the future.
    final next = saved.nextRunAt!.toLocal();
    expect(next.weekday, DateTime.tuesday);
    expect(next.hour, 9);
    expect(next.day, lessThanOrEqualTo(7));
    expect(next.isAfter(saved.createdAt), isTrue);
  });
}

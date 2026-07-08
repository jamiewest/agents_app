import 'package:agents_app/data/agent_task_store.dart';
import 'package:agents_app/data/task_scheduler_service.dart';
import 'package:agents_app/domain/agent_task.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryRecordStore records;
  late AgentTaskStore store;
  late ServiceProvider services;

  setUp(() {
    records = InMemoryRecordStore();
    store = AgentTaskStore(records);
    services =
        (ServiceCollection()..addRecordStore(recordStore: (_) => records))
            .buildServiceProvider();
  });

  AgentTask task({
    String id = 't1',
    int? intervalMinutes,
    DateTime? nextRunAt,
    AgentTaskStatus status = AgentTaskStatus.scheduled,
  }) => AgentTask(
    id: id,
    title: 'Check things',
    prompt: 'Check the things.',
    agentId: 'agent-1',
    intervalMinutes: intervalMinutes,
    status: status,
    nextRunAt: nextRunAt ?? DateTime.utc(2026, 7, 2, 9),
    createdAt: DateTime.utc(2026, 7, 1),
  );

  group('TaskSchedulerService.tick', () {
    test('runs due tasks and reschedules recurring ones', () async {
      final ran = <String>[];
      final now = DateTime.utc(2026, 7, 2, 10);
      final scheduler = TaskSchedulerService(
        services,
        runner: (task) async {
          ran.add(task.id);
          return 'ok';
        },
        now: () => now,
      );
      await store.save(task(id: 'due', intervalMinutes: 30));
      await store.save(
        task(id: 'future', nextRunAt: DateTime.utc(2026, 7, 2, 11)),
      );
      await store.save(task(id: 'paused', status: AgentTaskStatus.paused));

      await scheduler.tick();

      expect(ran, ['due']);
      final updated = (await store.get('due'))!;
      expect(updated.status, AgentTaskStatus.scheduled);
      expect(updated.lastRunAt, now);
      expect(updated.nextRunAt, now.add(const Duration(minutes: 30)));
    });

    test('one-shot tasks complete and never rerun', () async {
      var runs = 0;
      final scheduler = TaskSchedulerService(
        services,
        runner: (_) async {
          runs++;
          return 'ok';
        },
        now: () => DateTime.utc(2026, 7, 2, 10),
      );
      await store.save(task(id: 'once'));

      await scheduler.tick();
      await scheduler.tick();

      expect(runs, 1);
      expect((await store.get('once'))!.status, AgentTaskStatus.completed);
    });

    test('failures mark the task failed but keep the schedule', () async {
      final now = DateTime.utc(2026, 7, 2, 10);
      final scheduler = TaskSchedulerService(
        services,
        runner: (_) async => throw StateError('boom'),
        now: () => now,
      );
      await store.save(task(id: 'flaky', intervalMinutes: 15));

      await scheduler.tick();

      final updated = (await store.get('flaky'))!;
      expect(updated.status, AgentTaskStatus.failed);
      expect(updated.nextRunAt, now.add(const Duration(minutes: 15)));
    });

    test('runNow executes regardless of schedule', () async {
      final ran = <String>[];
      final scheduler = TaskSchedulerService(
        services,
        runner: (task) async {
          ran.add(task.id);
          return 'ok';
        },
        now: () => DateTime.utc(2026, 7, 2, 8),
      );
      await store.save(task(id: 'later', nextRunAt: DateTime.utc(2026, 7, 3)));

      await scheduler.runNow('later');

      expect(ran, ['later']);
    });
  });

  group('taskPromptMessage', () {
    ModelConfig model(Map<String, String> settings) => ModelConfig(
      id: 'm1',
      sourceId: 's1',
      modelId: 'gemma-4',
      settings: settings,
    );

    test('defaults to a hidden user message when no role is set', () {
      final message = taskPromptMessage('Do the thing.', model(const {}));

      expect(message.role, ai.ChatRole.user);
      expect(message.authorName, taskPromptAuthorName);
      expect(message.text, 'Do the thing.');
    });

    test('falls back to a hidden user message when the model is unknown', () {
      final message = taskPromptMessage('Do the thing.', null);

      expect(message.role, ai.ChatRole.user);
      expect(message.authorName, taskPromptAuthorName);
    });

    test('uses a system-role turn only when the model opts in', () {
      final message = taskPromptMessage(
        'Do the thing.',
        model(const {taskPromptRoleSetting: taskPromptRoleSystem}),
      );

      expect(message.role, ai.ChatRole.system);
      expect(message.authorName, isNull);
      expect(message.text, 'Do the thing.');
    });
  });
}

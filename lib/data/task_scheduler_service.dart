// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';

import '../domain/agent_task.dart';
import '../domain/conversation.dart';
import 'agent_task_store.dart';
import 'conversation_store.dart';

/// Executes one due [AgentTask] and returns a short outcome summary.
typedef AgentTaskRunner = Future<String> Function(AgentTask task);

/// Foreground scheduler for [AgentTask]s.
///
/// Ticks periodically while the app runs (there is no OS-level background
/// execution): due tasks execute through their agent in a dedicated task
/// conversation, so each run leaves a durable, inspectable transcript.
/// Recurring tasks reschedule; one-shot tasks complete.
class TaskSchedulerService {
  /// Creates a [TaskSchedulerService].
  ///
  /// [runner] and [now] are injectable for tests; the default runner builds
  /// the task's agent with a conversation scope and sends the prompt.
  TaskSchedulerService(
    this._services, {
    AgentTaskRunner? runner,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _runner = runner ?? _runWithAgent;
  }

  final ServiceProvider _services;
  final DateTime Function() _now;
  late final AgentTaskRunner _runner;
  Timer? _timer;

  AgentTaskStore get _tasks =>
      AgentTaskStore(_services.getRequiredService<RecordStore>());

  /// Starts the periodic tick.
  void start({Duration interval = const Duration(minutes: 1)}) {
    _timer ??= Timer.periodic(interval, (_) => unawaited(tick()));
  }

  /// Stops the periodic tick.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs every due task once. Public so tests can drive time directly.
  Future<void> tick() async {
    for (final task in await _tasks.listDue(_now())) {
      await _execute(task);
    }
  }

  /// Executes [task] immediately, regardless of schedule.
  Future<void> runNow(String taskId) async {
    final task = await _tasks.get(taskId);
    if (task != null) await _execute(task);
  }

  Future<void> _execute(AgentTask task) async {
    await _tasks.save(task.copyWith(status: AgentTaskStatus.running));
    final startedAt = _now();
    try {
      await _runner(task);
      await _finish(task, startedAt, failed: false);
    } catch (e, s) {
      developer.log(
        'Task "${task.title}" failed.',
        name: 'agents_app.tasks',
        error: e,
        stackTrace: s,
      );
      await _finish(task, startedAt, failed: true);
    }
  }

  Future<void> _finish(
    AgentTask task,
    DateTime startedAt, {
    required bool failed,
  }) async {
    final interval = task.intervalMinutes;
    final status = failed
        ? AgentTaskStatus.failed
        : interval == null
        ? AgentTaskStatus.completed
        : AgentTaskStatus.scheduled;
    await _tasks.save(
      task.copyWith(
        status: status,
        lastRunAt: startedAt,
        nextRunAt: interval == null
            ? task.nextRunAt
            : startedAt.add(Duration(minutes: interval)),
      ),
    );
  }

  /// Default runner: the task's agent executes the prompt inside the
  /// task's dedicated conversation, which is created on first run so the
  /// transcript is browsable from Chats.
  Future<String> _runWithAgent(AgentTask task) async {
    final manager = _services.getRequiredService<ConfiguredAgentsManager>();
    final factory = _services.getRequiredService<ConfiguredAgentFactory>();
    final records = _services.getRequiredService<RecordStore>();

    final agentConfig = await manager.agents.getAgent(task.agentId);
    if (agentConfig == null) {
      throw StateError('Task agent "${task.agentId}" no longer exists.');
    }

    final conversations = ConversationStore(records);
    final startedAt = _now();
    final existing = await conversations.get(task.taskConversationId);
    await conversations.save(
      existing?.copyWith(updatedAt: startedAt) ??
          Conversation(
            id: task.taskConversationId,
            kind: ConversationKind.direct,
            title: 'Task: ${task.title}',
            titleSource: ConversationTitleSource.summary,
            participantAgentIds: [agentConfig.id],
            channelId: task.channelId,
            createdAt: startedAt,
            updatedAt: startedAt,
          ),
    );

    final agent = await factory.createAgent(
      agentConfig,
      scope: AgentScope(
        conversationId: task.taskConversationId,
        channelId: task.channelId,
        sessionIdResolver: () => 'task-run',
      ),
    );
    final session = await agent.createSession();
    final response = await agent.run(session, null, message: task.prompt);
    return response.text;
  }
}

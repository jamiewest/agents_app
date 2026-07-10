// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';

import '../domain/agent_task.dart';
import '../domain/conversation.dart';
import 'agent_task_store.dart';
import 'conversation_store.dart';

/// Executes one due [AgentTask] and returns a short outcome summary.
typedef AgentTaskRunner = Future<String> Function(AgentTask task);

/// Builds the hidden prompt turn a task sends to its agent.
///
/// A task prompt is never shown as a message from the user. When [model] opts
/// in via [taskPromptRoleSetting] it is sent as a system-role message — only
/// safe for models whose chat template renders a standalone system turn (e.g.
/// Gemma). Otherwise it is a user message tagged [taskPromptAuthorName], which
/// every provider accepts and the chat view filters out of the transcript.
ai.ChatMessage taskPromptMessage(String prompt, ModelConfig? model) {
  final useSystemRole =
      model?.settings[taskPromptRoleSetting]?.trim() == taskPromptRoleSystem;
  return useSystemRole
      ? ai.ChatMessage.fromText(ai.ChatRole.system, prompt)
      : ai.ChatMessage(
          role: ai.ChatRole.user,
          contents: [ai.TextContent(prompt)],
          authorName: taskPromptAuthorName,
        );
}

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
  bool _ticking = false;

  AgentTaskStore get _tasks =>
      AgentTaskStore(_services.getRequiredService<RecordStore>());

  /// Starts the periodic tick, first recovering runs interrupted by an app
  /// restart.
  void start({Duration interval = const Duration(minutes: 1)}) {
    if (_timer != null) return;
    unawaited(recoverInterrupted());
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  /// Stops the periodic tick.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Marks tasks persisted as `running` — orphaned by an app kill mid-run —
  /// as failed. Recurring tasks become due immediately so the retry path
  /// picks them up; one-shot tasks stay manually runnable.
  Future<void> recoverInterrupted() async {
    for (final task in await _tasks.listRunning()) {
      developer.log(
        'Task "${task.title}" was interrupted by an app restart.',
        name: 'agents_app.tasks',
      );
      await _tasks.save(
        task.copyWith(
          status: AgentTaskStatus.failed,
          nextRunAt: task.intervalMinutes == null ? null : _now(),
        ),
      );
    }
  }

  /// Runs every due task once. Public so tests can drive time directly.
  ///
  /// Re-entrant calls no-op: a slow run must not overlap the next timer
  /// event.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      for (final task in await _tasks.listDue(_now())) {
        await _execute(task);
      }
    } finally {
      _ticking = false;
    }
  }

  /// Executes [task] immediately, regardless of schedule.
  ///
  /// No-ops when the task is already running.
  Future<void> runNow(String taskId) async {
    final task = await _tasks.get(taskId);
    if (task == null || task.status == AgentTaskStatus.running) return;
    await _execute(task);
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
  ///
  /// The prompt is never shown as a message from the user: it is delivered
  /// either as a system-role turn (models whose chat template supports a
  /// standalone system message, opted in via [taskPromptRoleSetting]) or as a
  /// user message tagged [taskPromptAuthorName] that the chat view hides. When
  /// the run finishes the conversation is marked unread so the chats list can
  /// surface the new message.
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
    final model = await manager.sources.getModel(agentConfig.modelId);
    final session = await agent.createSession();
    final response = await agent.run(
      session,
      null,
      messages: [taskPromptMessage(task.prompt, model)],
    );

    await _markConversationUnread(conversations, task, response.text);
    return response.text;
  }

  /// Flags the task conversation as unread and refreshes its list preview so
  /// the completed run shows up in the chats list.
  Future<void> _markConversationUnread(
    ConversationStore conversations,
    AgentTask task,
    String responseText,
  ) async {
    final conversation = await conversations.get(task.taskConversationId);
    if (conversation == null) return;
    final preview = responseText.trim();
    await conversations.save(
      conversation.copyWith(
        hasUnread: true,
        updatedAt: _now(),
        lastMessagePreview: preview.isEmpty ? null : preview,
      ),
    );
  }
}

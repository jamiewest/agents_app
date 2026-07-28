// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/agent_task_store.dart';
import '../../data/task_scheduler_service.dart';
import '../../domain/agent_task.dart';
import '../app_theme.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/empty_state.dart';
import '../widgets/task_editor_dialog.dart';

/// One task's page: what it does, when it repeats, and its run history's
/// conversation. Edit, pause, delete, and run-now all live here.
class TaskDetailScreen extends StatefulWidget {
  /// Creates a [TaskDetailScreen].
  const TaskDetailScreen({
    required this.services,
    required this.scheduler,
    required this.taskId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The scheduler used for run-now actions.
  final TaskSchedulerService scheduler;

  /// The task to show.
  final String taskId;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late final AgentTaskStore _tasks;
  Map<String, String> _agentNames = const {};

  @override
  void initState() {
    super.initState();
    _tasks = AgentTaskStore(widget.services.getRequiredService<RecordStore>());
    unawaited(_loadAgentNames());
  }

  Future<void> _loadAgentNames() async {
    final agents = await widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agents
        .listAgents();
    if (!mounted) return;
    setState(() => _agentNames = {for (final a in agents) a.id: a.name});
  }

  Future<void> _editTask(AgentTask task) async {
    final agents = await widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agents
        .listAgents();
    if (!mounted) return;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tasks need an agent to run.')),
      );
      return;
    }
    final edited = await showTaskEditorDialog(
      context,
      agents: agents,
      newId: _tasks.newTaskId,
      initial: task,
    );
    if (edited != null) await _tasks.save(edited);
  }

  Future<void> _deleteTask(AgentTask task) async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete task?',
      message:
          'Delete "${task.title}"? Its conversation is kept and stays '
          'available in Chats.',
      confirmLabel: 'Delete task',
    );
    if (!confirmed) return;
    await _tasks.delete(task.id);
    if (mounted) context.go('/tasks');
  }

  Future<void> _togglePause(AgentTask task) => _tasks.save(
    task.copyWith(
      status: task.status == AgentTaskStatus.paused
          ? AgentTaskStatus.scheduled
          : AgentTaskStatus.paused,
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: StreamBuilder<List<AgentTask>>(
      stream: _tasks.watchAll(),
      builder: (context, snapshot) {
        final tasks = snapshot.data;
        if (tasks == null) {
          return const Center(child: CircularProgressIndicator());
        }
        AgentTask? task;
        for (final candidate in tasks) {
          if (candidate.id == widget.taskId) task = candidate;
        }
        if (task == null) return _missing(context);
        return _TaskDetailBody(
          task: task,
          agentName: _agentNames[task.agentId],
          // Editing mid-run would race the scheduler's status updates.
          onEdit: task.status == AgentTaskStatus.running
              ? null
              : () => _editTask(task!),
          onDelete: () => _deleteTask(task!),
          onTogglePause: () => _togglePause(task!),
          onRunNow: task.status == AgentTaskStatus.running
              ? null
              : () => widget.scheduler.runNow(task!.id),
        );
      },
    ),
  );

  Widget _missing(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar(
        pinned: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: LucideIcons.timer300,
          title: 'Task not found',
          message: 'This task was deleted.',
        ),
      ),
    ],
  );
}

class _TaskDetailBody extends StatelessWidget {
  const _TaskDetailBody({
    required this.task,
    required this.agentName,
    required this.onEdit,
    required this.onDelete,
    required this.onTogglePause,
    required this.onRunNow,
  });

  final AgentTask task;
  final String? agentName;

  /// Edit handler; `null` while the task is running.
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTogglePause;

  /// Run-now handler; `null` while the task is already running.
  final VoidCallback? onRunNow;

  static String _timestamp(DateTime time) =>
      time.toLocal().toString().substring(0, 16);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paused = task.status == AgentTaskStatus.paused;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: theme.scaffoldBackgroundColor,
          scrolledUnderElevation: 0,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(LucideIcons.pencil300),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(LucideIcons.trash2300),
              onPressed: onDelete,
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton.tonalIcon(
              onPressed: onTogglePause,
              icon: Icon(
                paused ? LucideIcons.circlePlay300 : LucideIcons.circlePause300,
                size: 18,
              ),
              label: Text(paused ? 'Resume' : 'Pause'),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton.icon(
              onPressed: onRunNow,
              icon: const Icon(LucideIcons.play300, size: 18),
              label: const Text('Run now'),
            ),
            const SizedBox(width: AppSpacing.lg),
          ],
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.title, style: theme.textTheme.headlineMedium),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        _StatusChip(status: task.status),
                        _InfoChip(
                          icon: LucideIcons.clock300,
                          label: taskScheduleLabel(task.schedule),
                        ),
                        if (agentName case final name?)
                          _InfoChip(icon: LucideIcons.bot300, label: name),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                    const Divider(),
                    _Section(
                      label: 'Instructions',
                      child: Text(
                        task.prompt,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    _Section(
                      label: 'Repeats',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: AppSpacing.xs,
                        children: [
                          Text(
                            task.schedule == null
                                ? 'Runs once, while the app is open.'
                                : '${taskScheduleLabel(task.schedule)} '
                                      'while the app is open.',
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (task.nextRunAt case final next?)
                            if (task.status == AgentTaskStatus.scheduled)
                              Text(
                                'Next run ${_timestamp(next)}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          if (task.lastRunAt case final last?)
                            Text(
                              'Last ran ${_timestamp(last)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    _Section(
                      label: 'Runs',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: AppSpacing.md,
                        children: [
                          Text(
                            'Every run continues the same conversation, so '
                            'the full history stays in one place.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => context.go(
                              '/chats/c/${task.taskConversationId}',
                            ),
                            icon: const Icon(
                              LucideIcons.messagesSquare300,
                              size: 18,
                            ),
                            label: const Text('Open conversation'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The task's lifecycle state as a tinted chip.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final AgentTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Fall back to primary under themes without the app's status colors
    // (bare MaterialApp hosts in tests).
    final online = theme.extension<StatusColors>()?.online ?? scheme.primary;
    final (icon, label, color) = switch (status) {
      AgentTaskStatus.scheduled => (LucideIcons.clock300, 'Active', online),
      AgentTaskStatus.running => (
        LucideIcons.circlePlay300,
        'Running',
        scheme.primary,
      ),
      AgentTaskStatus.paused => (
        LucideIcons.circlePause300,
        'Paused',
        scheme.onSurfaceVariant,
      ),
      AgentTaskStatus.failed => (
        LucideIcons.circleAlert300,
        'Failed',
        scheme.error,
      ),
      AgentTaskStatus.completed => (
        LucideIcons.circleCheck300,
        'Done',
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppShape.small),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.xs,
        children: [
          Icon(icon, size: 15, color: color),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A neutral icon-and-label chip for schedule and agent facts.
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppShape.small),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.xs,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A labeled block in the detail column: muted heading, content below.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.sm,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

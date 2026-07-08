// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/agent_task_store.dart';
import '../../data/task_scheduler_service.dart';
import '../../domain/agent_task.dart';
import '../app_theme.dart';
import '../widgets/app_sliver_header.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/empty_state.dart';

/// The Tasks destination: scheduled and background agent work.
///
/// Tasks run while the app is open (foreground scheduler); each run
/// executes in the task's own conversation, reachable from the row.
class TasksScreen extends StatefulWidget {
  /// Creates a [TasksScreen].
  const TasksScreen({
    required this.services,
    required this.scheduler,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The scheduler used for run-now actions.
  final TaskSchedulerService scheduler;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  late final AgentTaskStore _tasks;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _tasks = AgentTaskStore(widget.services.getRequiredService<RecordStore>());
  }

  Future<void> _createTask() async {
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final agents = await manager.agents.listAgents();
    if (!mounted) return;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Tasks need an agent to run.'),
          action: SnackBarAction(
            label: 'Add agent',
            onPressed: () => context.go('/settings/agents/add'),
          ),
        ),
      );
      return;
    }

    final created = await showDialog<AgentTask>(
      context: context,
      builder: (context) =>
          _CreateTaskDialog(agents: agents, newId: _tasks.newTaskId),
    );
    if (created != null) await _tasks.save(created);
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
        return CustomScrollView(
          slivers: [
            AppSliverHeader(
              title: 'Tasks',
              actions: [
                IconButton(
                  tooltip: 'New task',
                  icon: const Icon(Symbols.add_task),
                  onPressed: _createTask,
                ),
              ],
            ),
            if (tasks == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (tasks.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Symbols.task_alt,
                  title: 'No tasks yet',
                  message:
                      'Tasks run while the app is open and leave a '
                      'conversation you can inspect.',
                  actionLabel: 'New task',
                  onAction: _createTask,
                ),
              )
            else
              SliverList.builder(
                itemCount: tasks.length,
                itemBuilder: (context, index) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: _taskTile(context, tasks[index]),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _taskTile(BuildContext context, AgentTask task) {
    final next = task.nextRunAt;
    final paused = task.status == AgentTaskStatus.paused;
    return ListTile(
      leading: Icon(switch (task.status) {
        AgentTaskStatus.running => Symbols.play_circle,
        AgentTaskStatus.paused => Symbols.pause_circle,
        AgentTaskStatus.failed => Symbols.error,
        AgentTaskStatus.completed => Symbols.check_circle,
        AgentTaskStatus.scheduled => Symbols.schedule,
      }),
      title: Text(task.title),
      subtitle: Text(
        [
          task.status.name,
          if (task.intervalMinutes case final interval?) 'every ${interval}m',
          if (next != null && task.status == AgentTaskStatus.scheduled)
            'next ${next.toLocal().toString().substring(0, 16)}',
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => context.go('/chats/c/${task.taskConversationId}'),
      trailing: PopupMenuButton<String>(
        tooltip: 'Task actions',
        onSelected: (action) async {
          switch (action) {
            case 'run':
              await widget.scheduler.runNow(task.id);
            case 'pause':
              await _togglePause(task);
            case 'delete':
              final confirmed = await showDeleteConfirmation(
                context,
                title: 'Delete task?',
                message:
                    'Delete "${task.title}"? Its conversation is kept and '
                    'stays available in Chats.',
                confirmLabel: 'Delete task',
              );
              if (confirmed) await _tasks.delete(task.id);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'run', child: Text('Run now')),
          PopupMenuItem(
            value: 'pause',
            child: Text(paused ? 'Resume' : 'Pause'),
          ),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

class _CreateTaskDialog extends StatefulWidget {
  const _CreateTaskDialog({required this.agents, required this.newId});

  final List<SavedAgentConfig> agents;
  final String Function() newId;

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  /// Sentinel for "run once" so [SegmentedButton] gets a non-null value.
  static const int _runOnce = 0;

  final _titleController = TextEditingController();
  final _promptController = TextEditingController();
  late String _agentId = widget.agents.first.id;
  int _repeatMinutes = _runOnce;

  bool get _valid =>
      _titleController.text.trim().isNotEmpty &&
      _promptController.text.trim().isNotEmpty;

  String get _scheduleSummary => switch (_repeatMinutes) {
    _runOnce => 'Runs once, right away, while the app is open.',
    15 => 'Runs every 15 minutes while the app is open.',
    60 => 'Runs every hour while the app is open.',
    _ => 'Runs every day while the app is open.',
  };

  @override
  void dispose() {
    _titleController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(
      AgentTask(
        id: widget.newId(),
        title: _titleController.text.trim(),
        prompt: _promptController.text.trim(),
        agentId: _agentId,
        intervalMinutes: _repeatMinutes == _runOnce ? null : _repeatMinutes,
        status: AgentTaskStatus.scheduled,
        nextRunAt: DateTime.now(),
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: const Text('New task'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppSpacing.lg,
            children: [
              TextField(
                controller: _titleController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Morning news digest',
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _promptController,
                minLines: 3,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  hintText: 'What should the agent do each run?',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              DropdownButtonFormField<String>(
                initialValue: _agentId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [
                  for (final agent in widget.agents)
                    DropdownMenuItem(
                      value: agent.id,
                      child: Text(agent.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _agentId = value ?? _agentId),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.sm,
                children: [
                  Text('Repeat', style: labelStyle),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _runOnce, label: Text('Once')),
                        ButtonSegment(value: 15, label: Text('15 min')),
                        ButtonSegment(value: 60, label: Text('Hourly')),
                        ButtonSegment(value: 1440, label: Text('Daily')),
                      ],
                      selected: {_repeatMinutes},
                      onSelectionChanged: (selection) =>
                          setState(() => _repeatMinutes = selection.first),
                    ),
                  ),
                  Text(
                    _scheduleSummary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

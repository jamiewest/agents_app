// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/agent_task_store.dart';
import '../../data/task_scheduler_service.dart';
import '../../domain/agent_task.dart';

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add an agent first.')));
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
    appBar: AppBar(
      title: const Text('Tasks'),
      actions: [
        IconButton(
          tooltip: 'New task',
          icon: const Icon(Icons.add_task_outlined),
          onPressed: _createTask,
        ),
      ],
    ),
    body: StreamBuilder<List<AgentTask>>(
      stream: _tasks.watchAll(),
      builder: (context, snapshot) {
        final tasks = snapshot.data;
        if (tasks == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (tasks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'No tasks yet. Tasks run while the app is open and '
                    'leave a conversation you can inspect.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _createTask,
                    icon: const Icon(Icons.add),
                    label: const Text('New task'),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (context, index) => _taskTile(context, tasks[index]),
        );
      },
    ),
  );

  Widget _taskTile(BuildContext context, AgentTask task) {
    final next = task.nextRunAt;
    final paused = task.status == AgentTaskStatus.paused;
    return ListTile(
      leading: Icon(switch (task.status) {
        AgentTaskStatus.running => Icons.play_circle_outline,
        AgentTaskStatus.paused => Icons.pause_circle_outline,
        AgentTaskStatus.failed => Icons.error_outline,
        AgentTaskStatus.completed => Icons.check_circle_outline,
        AgentTaskStatus.scheduled => Icons.schedule_outlined,
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
              await _tasks.delete(task.id);
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
  String _title = '';
  String _prompt = '';
  String? _agentId;
  int? _intervalMinutes;

  bool get _valid => _title.trim().isNotEmpty && _prompt.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New task'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            onChanged: (value) => setState(() => _title = value),
          ),
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'Prompt',
              hintText: 'What should the agent do each run?',
            ),
            maxLines: 3,
            onChanged: (value) => setState(() => _prompt = value),
          ),
          DropdownButtonFormField<String>(
            initialValue: _agentId ?? widget.agents.first.id,
            decoration: const InputDecoration(labelText: 'Agent'),
            items: [
              for (final agent in widget.agents)
                DropdownMenuItem(value: agent.id, child: Text(agent.name)),
            ],
            onChanged: (value) => setState(() => _agentId = value),
          ),
          DropdownButtonFormField<int?>(
            initialValue: _intervalMinutes,
            decoration: const InputDecoration(labelText: 'Repeat'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Run once')),
              DropdownMenuItem(value: 15, child: Text('Every 15 minutes')),
              DropdownMenuItem(value: 60, child: Text('Every hour')),
              DropdownMenuItem(value: 1440, child: Text('Every day')),
            ],
            onChanged: (value) => setState(() => _intervalMinutes = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: !_valid
            ? null
            : () => Navigator.of(context).pop(
                AgentTask(
                  id: widget.newId(),
                  title: _title.trim(),
                  prompt: _prompt.trim(),
                  agentId: _agentId ?? widget.agents.first.id,
                  intervalMinutes: _intervalMinutes,
                  status: AgentTaskStatus.scheduled,
                  nextRunAt: DateTime.now(),
                  createdAt: DateTime.now(),
                ),
              ),
        child: const Text('Create'),
      ),
    ],
  );
}

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
import '../widgets/app_sliver_header.dart';
import '../widgets/empty_state.dart';
import '../widgets/task_editor_dialog.dart';

/// How the task list is ordered.
enum _TaskSort {
  nextRun('Next run'),
  name('Name'),
  created('Created');

  const _TaskSort(this.label);

  /// Menu label.
  final String label;
}

/// The Tasks destination: scheduled and background agent work.
///
/// Tasks run while the app is open (foreground scheduler); each run
/// executes in the task's own conversation, reachable from the task's
/// detail page. Below the list, a gallery of templates prefills the
/// create dialog with common task ideas.
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
  /// Key marking the intro banner as dismissed, so it stays gone.
  static const String _bannerDismissedKey =
      'agents_app.tasks.intro_banner_dismissed';

  late final AgentTaskStore _tasks;
  late final KeyValueStore _keyValues;
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  _TaskSort _sort = _TaskSort.nextRun;

  /// Whether the intro banner was dismissed; `null` while loading (the
  /// banner stays hidden rather than flashing in and out).
  bool? _bannerDismissed;

  @override
  void initState() {
    super.initState();
    _tasks = AgentTaskStore(widget.services.getRequiredService<RecordStore>());
    _keyValues = widget.services.getRequiredService<KeyValueStore>();
    unawaited(_loadBannerState());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadBannerState() async {
    final dismissed = await _keyValues.read(_bannerDismissedKey) == 'true';
    if (mounted) setState(() => _bannerDismissed = dismissed);
  }

  Future<void> _dismissBanner() async {
    setState(() => _bannerDismissed = true);
    await _keyValues.write(_bannerDismissedKey, 'true');
  }

  Future<List<SavedAgentConfig>> _agents() => widget.services
      .getRequiredService<ConfiguredAgentsManager>()
      .agents
      .listAgents();

  Future<void> _createTask({AgentTaskTemplate? template}) async {
    final agents = await _agents();
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

    final created = await showTaskEditorDialog(
      context,
      agents: agents,
      newId: _tasks.newTaskId,
      template: template,
    );
    if (created != null) await _tasks.save(created);
  }

  List<AgentTask> _visibleTasks(List<AgentTask> tasks) {
    final query = _search.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? [...tasks]
        : [
            for (final task in tasks)
              if (task.title.toLowerCase().contains(query) ||
                  task.prompt.toLowerCase().contains(query))
                task,
          ];
    switch (_sort) {
      case _TaskSort.nextRun:
        // Soonest first; tasks with no next run (done, paused one-shots)
        // sink to the end in stored order.
        filtered.sort(
          (a, b) => switch ((a.nextRunAt, b.nextRunAt)) {
            (null, null) => 0,
            (null, _) => 1,
            (_, null) => -1,
            (final x?, final y?) => x.compareTo(y),
          },
        );
      case _TaskSort.name:
        filtered.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case _TaskSort.created:
        break;
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return Scaffold(
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
                    tooltip: _searching ? 'Close search' : 'Search tasks',
                    icon: Icon(
                      _searching ? LucideIcons.x300 : LucideIcons.search300,
                    ),
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _search.clear();
                    }),
                  ),
                  _SortMenu(
                    sort: _sort,
                    compact: compact,
                    onSelected: (sort) => setState(() => _sort = sort),
                  ),
                  if (compact)
                    IconButton(
                      tooltip: 'New task',
                      icon: const Icon(LucideIcons.listPlus300),
                      onPressed: _createTask,
                    )
                  else
                    FilledButton.icon(
                      onPressed: _createTask,
                      icon: const Icon(LucideIcons.plus300, size: 18),
                      label: const Text('New task'),
                    ),
                  const SizedBox(width: AppSpacing.lg),
                ],
              ),
              _centered(
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                  child: Text(
                    'Run tasks on a schedule or whenever you need them.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (_searching)
                _centered(
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search tasks',
                        prefixIcon: Icon(LucideIcons.search300, size: 18),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
              if (_bannerDismissed == false)
                _centered(
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    child: _IntroBanner(onDismiss: _dismissBanner),
                  ),
                ),
              if (tasks == null)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.xxxl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else ...[
                _taskListSliver(_visibleTasks(tasks), tasks.isEmpty),
                _centered(
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xxl,
                    ),
                    child: _WavyDivider(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                _centered(
                  _TemplateGallery(
                    onSelected: (template) => _createTask(template: template),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.xxxl),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Wraps [child] in the page's centered 720-wide content column.
  Widget _centered(Widget child) => SliverToBoxAdapter(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: child,
        ),
      ),
    ),
  );

  Widget _taskListSliver(List<AgentTask> visible, bool storeEmpty) {
    if (storeEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
          child: EmptyState(
            icon: LucideIcons.timer300,
            title: 'No scheduled tasks yet.',
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
          child: EmptyState(
            icon: LucideIcons.search300,
            title: 'No tasks match your search.',
          ),
        ),
      );
    }
    return _centered(
      LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 560;
          final width = twoColumns
              ? (constraints.maxWidth - AppSpacing.lg) / 2
              : constraints.maxWidth;
          return Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.lg,
            children: [
              for (final task in visible)
                SizedBox(
                  width: width,
                  child: _TaskCard(task: task),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The "Sort by …" control: a text trigger on wide layouts, an icon on
/// compact ones.
class _SortMenu extends StatelessWidget {
  const _SortMenu({
    required this.sort,
    required this.compact,
    required this.onSelected,
  });

  final _TaskSort sort;
  final bool compact;
  final ValueChanged<_TaskSort> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<_TaskSort>(
      tooltip: 'Sort',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in _TaskSort.values)
          CheckedPopupMenuItem(
            value: option,
            checked: option == sort,
            child: Text(option.label),
          ),
      ],
      child: compact
          ? Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Icon(
                LucideIcons.arrowUpDown300,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: AppSpacing.xs,
                children: [
                  Text(
                    'Sort by ${sort.label}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Icon(
                    LucideIcons.chevronDown300,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
    );
  }
}

/// Dismissible first-run explainer for how tasks execute.
class _IntroBanner extends StatelessWidget {
  const _IntroBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppShape.card),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.sm,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(AppShape.small),
                  ),
                  child: Text(
                    'New',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'Tasks run while the app is open. ',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text:
                            'Each run executes in the task’s own '
                            'conversation, so you can open it any time to '
                            'see what the agent did.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(LucideIcons.x300, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// One task in the list: title, status, and its schedule at a glance.
/// Tapping opens the task's detail page.
class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final AgentTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final next = task.nextRunAt;
    final schedule = [
      taskScheduleLabel(task.schedule),
      if (next != null && task.status == AgentTaskStatus.scheduled)
        'next ${next.toLocal().toString().substring(0, 16)}',
    ].join(' • ');
    final (statusIcon, statusColor) = switch (task.status) {
      AgentTaskStatus.scheduled => (null, null),
      AgentTaskStatus.running => (LucideIcons.circlePlay300, scheme.primary),
      AgentTaskStatus.paused => (
        LucideIcons.circlePause300,
        scheme.onSurfaceVariant,
      ),
      AgentTaskStatus.failed => (LucideIcons.circleAlert300, scheme.error),
      AgentTaskStatus.completed => (
        LucideIcons.circleCheck300,
        scheme.onSurfaceVariant,
      ),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShape.card),
        onTap: () => context.go('/tasks/t/${task.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppSpacing.sm,
            children: [
              Row(
                spacing: AppSpacing.sm,
                children: [
                  Expanded(
                    child: Text(
                      task.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (statusIcon != null)
                    Icon(statusIcon, size: 18, color: statusColor),
                ],
              ),
              Row(
                spacing: AppSpacing.sm,
                children: [
                  Icon(
                    LucideIcons.clock300,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Text(
                      schedule,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The template gallery: common task ideas that prefill the create dialog.
class _TemplateGallery extends StatelessWidget {
  const _TemplateGallery({required this.onSelected});

  final ValueChanged<AgentTaskTemplate> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final twoColumns = constraints.maxWidth >= 560;
      final width = twoColumns
          ? (constraints.maxWidth - AppSpacing.xl) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: AppSpacing.xl,
        runSpacing: AppSpacing.xl,
        children: [
          for (final template in agentTaskTemplates)
            SizedBox(
              width: width,
              child: _TemplateTile(
                template: template,
                onTap: () => onSelected(template),
              ),
            ),
        ],
      );
    },
  );
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template, required this.onTap});

  final AgentTaskTemplate template;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppShape.inner),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.lg,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppShape.inner),
              ),
              child: Icon(
                template.icon,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.xs,
                children: [
                  Text(template.title, style: theme.textTheme.titleSmall),
                  Text(
                    template.description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    spacing: AppSpacing.xs,
                    children: [
                      Icon(
                        LucideIcons.clock300,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      Text(
                        taskScheduleLabel(template.schedule),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A gentle sine-wave rule separating the user's tasks from the template
/// gallery.
class _WavyDivider extends StatelessWidget {
  const _WavyDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 8,
    width: double.infinity,
    child: CustomPaint(painter: _WavyDividerPainter(color: color)),
  );
}

class _WavyDividerPainter extends CustomPainter {
  const _WavyDividerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final mid = size.height / 2;
    final path = Path()..moveTo(0, mid);
    var up = true;
    for (var x = 0.0; x + 12 <= size.width; x += 12) {
      path.quadraticBezierTo(x + 6, up ? 0 : size.height, x + 12, mid);
      up = !up;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WavyDividerPainter oldDelegate) =>
      color != oldDelegate.color;
}

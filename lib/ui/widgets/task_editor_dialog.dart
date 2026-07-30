// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';

/// A prefilled starting point for a new task, shown in the Tasks gallery.
class AgentTaskTemplate {
  /// Creates an [AgentTaskTemplate].
  const AgentTaskTemplate({
    required this.icon,
    required this.title,
    required this.description,
    required this.prompt,
    required this.schedule,
  });

  /// Gallery icon.
  final IconData icon;

  /// Task title the template prefills.
  final String title;

  /// Short gallery copy describing the task.
  final String description;

  /// The instruction the template prefills.
  final String prompt;

  /// Prefilled repeat schedule; `null` means run once.
  final TaskSchedule? schedule;
}

/// Built-in task ideas shown below the task list.
///
/// Tapping one opens the editor prefilled — they are suggestions, not
/// separate task kinds.
const List<AgentTaskTemplate> agentTaskTemplates = [
  AgentTaskTemplate(
    icon: LucideIcons.listChecks300,
    title: 'Weekly review',
    description: 'A summary of what happened this week.',
    prompt:
        'Write a short review of the past week: what was worked on, what '
        'changed, and anything that needs follow-up next week.',
    schedule: IntervalSchedule(10080),
  ),
  AgentTaskTemplate(
    icon: LucideIcons.mailbox300,
    title: 'Inbox triage',
    description: 'Categorize your inbox and draft replies to anything urgent.',
    prompt:
        'Go through my unread messages, group them by urgency, and draft '
        'replies to anything that needs a response today.',
    schedule: IntervalSchedule(1440),
  ),
  AgentTaskTemplate(
    icon: LucideIcons.binoculars300,
    title: 'Monitor a topic',
    description: 'Watch for news or mentions of a topic or keyword.',
    prompt:
        'Search for recent news about <topic> and summarize anything '
        'noteworthy since the last run.',
    schedule: IntervalSchedule(1440),
  ),
  AgentTaskTemplate(
    icon: LucideIcons.calendar300,
    title: 'Meeting prep',
    description: 'A short brief before each meeting on your calendar.',
    prompt:
        "Look at today's meetings and write a short brief for each: "
        'attendees, context, and a suggested agenda.',
    schedule: IntervalSchedule(1440),
  ),
  AgentTaskTemplate(
    icon: LucideIcons.lightbulb300,
    title: 'Content ideas',
    description: 'Draft a few post ideas from the latest news.',
    prompt:
        'Draft three post ideas based on recent news in my industry, each '
        'with a hook and a short outline.',
    schedule: IntervalSchedule(10080),
  ),
  AgentTaskTemplate(
    icon: LucideIcons.sunrise300,
    title: 'Daily briefing',
    description: 'What needs your attention today.',
    prompt:
        'Put together a morning briefing: what needs my attention today and '
        'anything left unfinished from yesterday.',
    schedule: IntervalSchedule(1440),
  ),
];

/// Weekday names indexed by [DateTime.monday] through [DateTime.sunday].
const List<String> _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Week-of-month names indexed by week 1–4, then
/// [MonthlyWeekdaySchedule.lastWeek].
const List<String> _weekNames = ['first', 'second', 'third', 'fourth', 'last'];

String _weekdayName(int weekday) => _weekdayNames[weekday - 1];

/// Dropdown labels for the week-of-month picker, same indexing as
/// [_weekNames].
const List<String> _weekOfMonthLabels = [
  'First',
  'Second',
  'Third',
  'Fourth',
  'Last',
];

/// A "9:00 AM"-style label.
String _timeLabel(int hour, int minute) {
  final period = hour < 12 ? 'AM' : 'PM';
  final display = switch (hour % 12) {
    0 => 12,
    final h => h,
  };
  return '$display:${minute.toString().padLeft(2, '0')} $period';
}

/// A "1st"/"2nd"/"15th"-style ordinal for a day of the month.
String _dayOrdinal(int day) {
  final suffix = switch (day % 100) {
    11 || 12 || 13 => 'th',
    _ => switch (day % 10) {
      1 => 'st',
      2 => 'nd',
      3 => 'rd',
      _ => 'th',
    },
  };
  return '$day$suffix';
}

/// Human-readable description of [schedule]; `null` means run once.
String taskScheduleLabel(TaskSchedule? schedule) => switch (schedule) {
  null => 'Runs once',
  IntervalSchedule(minutes: 15) => 'Every 15 minutes',
  IntervalSchedule(minutes: 30) => 'Every 30 minutes',
  IntervalSchedule(minutes: 60) => 'Every hour',
  IntervalSchedule(minutes: 1440) => 'Every day',
  IntervalSchedule(minutes: 10080) => 'Every week',
  IntervalSchedule(minutes: 20160) => 'Every 2 weeks',
  IntervalSchedule(:final minutes) => 'Every $minutes minutes',
  WeeklySchedule(:final weekday, :final hour, :final minute) =>
    'Every ${_weekdayName(weekday)} at ${_timeLabel(hour, minute)}',
  MonthlyDaySchedule(:final day, :final hour, :final minute) =>
    'The ${_dayOrdinal(day)} of every month at ${_timeLabel(hour, minute)}',
  MonthlyWeekdaySchedule(
    :final week,
    :final weekday,
    :final hour,
    :final minute,
  ) =>
    'The ${_weekNames[week - 1]} ${_weekdayName(weekday)} of every month '
        'at ${_timeLabel(hour, minute)}',
};

/// Shows the create/edit task dialog.
///
/// Returns the task to save, or `null` when cancelled. [initial] switches
/// the dialog to editing (preserving the task's id, conversation, and run
/// history); [template] prefills a new task from the gallery.
Future<AgentTask?> showTaskEditorDialog(
  BuildContext context, {
  required List<SavedAgentConfig> agents,
  required String Function() newId,
  AgentTask? initial,
  AgentTaskTemplate? template,
}) => showDialog<AgentTask>(
  context: context,
  builder: (context) => _TaskEditorDialog(
    agents: agents,
    newId: newId,
    initial: initial,
    template: template,
  ),
);

class _TaskEditorDialog extends StatefulWidget {
  const _TaskEditorDialog({
    required this.agents,
    required this.newId,
    this.initial,
    this.template,
  });

  final List<SavedAgentConfig> agents;
  final String Function() newId;
  final AgentTask? initial;
  final AgentTaskTemplate? template;

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

/// The choices in the frequency dropdown.
///
/// Interval presets carry their minutes; the calendar kinds (`null` minutes,
/// other than [once]) reveal follow-up pickers for the day and time.
enum _Frequency {
  once('Run once'),
  every15('Every 15 minutes', 15),
  every30('Every 30 minutes', 30),
  hourly('Every hour', 60),
  daily('Every day', 1440),
  weekly('Every week', 10080),
  biweekly('Every 2 weeks', 20160),
  weekdayOfWeek('Weekly on a day…'),
  dayOfMonth('Monthly on a date…'),
  weekdayOfMonth('Monthly on a weekday…');

  const _Frequency(this.label, [this.minutes]);

  /// Dropdown item text.
  final String label;

  /// Interval length for preset choices; `null` for [once] and the
  /// calendar kinds.
  final int? minutes;
}

class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  late final _titleController = TextEditingController(
    text: widget.initial?.title ?? widget.template?.title ?? '',
  );
  late final _promptController = TextEditingController(
    text: widget.initial?.prompt ?? widget.template?.prompt ?? '',
  );
  late String _agentId = _initialAgentId();

  _Frequency _frequency = _Frequency.once;
  int _weekday = DateTime.monday;
  int _monthDay = 1;
  int _week = 1;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final schedule = _editing
        ? widget.initial?.schedule
        : widget.template?.schedule;
    switch (schedule) {
      case null:
        _frequency = _Frequency.once;
      case IntervalSchedule(:final minutes):
        // Every interval the app ever wrote matches a preset; anything else
        // (a hand-edited record) falls back to daily rather than crashing
        // the dropdown.
        _frequency = _Frequency.values.firstWhere(
          (f) => f.minutes == minutes,
          orElse: () => _Frequency.daily,
        );
      case WeeklySchedule(:final weekday, :final hour, :final minute):
        _frequency = _Frequency.weekdayOfWeek;
        _weekday = weekday;
        _time = TimeOfDay(hour: hour, minute: minute);
      case MonthlyDaySchedule(:final day, :final hour, :final minute):
        _frequency = _Frequency.dayOfMonth;
        _monthDay = day;
        _time = TimeOfDay(hour: hour, minute: minute);
      case MonthlyWeekdaySchedule(
        :final week,
        :final weekday,
        :final hour,
        :final minute,
      ):
        _frequency = _Frequency.weekdayOfMonth;
        _week = week;
        _weekday = weekday;
        _time = TimeOfDay(hour: hour, minute: minute);
    }
  }

  /// The schedule the current picker state describes; `null` is run once.
  TaskSchedule? get _schedule => switch (_frequency) {
    _Frequency.once => null,
    _Frequency.weekdayOfWeek => WeeklySchedule(
      weekday: _weekday,
      hour: _time.hour,
      minute: _time.minute,
    ),
    _Frequency.dayOfMonth => MonthlyDaySchedule(
      day: _monthDay,
      hour: _time.hour,
      minute: _time.minute,
    ),
    _Frequency.weekdayOfMonth => MonthlyWeekdaySchedule(
      week: _week,
      weekday: _weekday,
      hour: _time.hour,
      minute: _time.minute,
    ),
    final preset => IntervalSchedule(preset.minutes!),
  };

  /// The initial agent, falling back to the first when the task's agent has
  /// since been deleted.
  String _initialAgentId() {
    final wanted = widget.initial?.agentId;
    if (wanted != null && widget.agents.any((a) => a.id == wanted)) {
      return wanted;
    }
    return widget.agents.first.id;
  }

  bool get _valid =>
      _titleController.text.trim().isNotEmpty &&
      _promptController.text.trim().isNotEmpty;

  String get _scheduleSummary => switch (_schedule) {
    null => 'Runs once, right away, while the app is open.',
    final schedule => '${taskScheduleLabel(schedule)} while the app is open.',
  };

  @override
  void dispose() {
    _titleController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_valid) return;
    final initial = widget.initial;
    final schedule = _schedule;
    final now = DateTime.now();
    // A new calendar schedule waits for its next occurrence; a new interval
    // (or one-shot) task runs right away. Editing keeps the task's current
    // timing unless the schedule itself changed, in which case the new
    // cadence restarts from now.
    final nextRunAt = switch (schedule) {
      CalendarSchedule() when initial == null || schedule != initial.schedule =>
        schedule.nextRunAfter(now),
      IntervalSchedule() when initial != null && schedule != initial.schedule =>
        schedule.nextRunAfter(now),
      _ => initial?.nextRunAt ?? now,
    };
    // Editing preserves the task's id (and so its conversation), creation
    // time, and run history; only the editable fields change.
    Navigator.of(context).pop(
      AgentTask(
        id: initial?.id ?? widget.newId(),
        title: _titleController.text.trim(),
        prompt: _promptController.text.trim(),
        agentId: _agentId,
        channelId: initial?.channelId,
        schedule: schedule,
        status: initial?.status ?? AgentTaskStatus.scheduled,
        nextRunAt: nextRunAt,
        lastRunAt: initial?.lastRunAt,
        createdAt: initial?.createdAt ?? now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing
                          ? 'Edit scheduled task'
                          : 'Create scheduled task',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(LucideIcons.x300),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AppSpacing.lg,
                    children: [
                      TextField(
                        controller: _titleController,
                        autofocus: !_editing,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Daily briefing',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      _PromptField(
                        controller: _promptController,
                        agentChip: _AgentPickerChip(
                          agents: widget.agents,
                          selectedId: _agentId,
                          onSelected: (id) => setState(() => _agentId = id),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      Row(
                        children: [
                          Text(
                            'Frequency',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.lg),
                          SizedBox(
                            width: 220,
                            child: DropdownButtonFormField<_Frequency>(
                              initialValue: _frequency,
                              isDense: true,
                              isExpanded: true,
                              items: [
                                for (final frequency in _Frequency.values)
                                  DropdownMenuItem(
                                    value: frequency,
                                    child: Text(frequency.label),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => _frequency = value ?? _frequency,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_frequency
                          case _Frequency.weekdayOfWeek ||
                              _Frequency.dayOfMonth ||
                              _Frequency.weekdayOfMonth)
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (_frequency == _Frequency.weekdayOfMonth)
                              _PickerDropdown(
                                key: const ValueKey('week-of-month'),
                                width: 120,
                                value: _week,
                                items: [
                                  for (var week = 1; week <= 5; week++)
                                    (week, _weekOfMonthLabels[week - 1]),
                                ],
                                onChanged: (value) =>
                                    setState(() => _week = value),
                              ),
                            if (_frequency == _Frequency.dayOfMonth)
                              _PickerDropdown(
                                key: const ValueKey('day-of-month'),
                                width: 110,
                                value: _monthDay,
                                items: [
                                  for (var day = 1; day <= 31; day++)
                                    (day, _dayOrdinal(day)),
                                ],
                                onChanged: (value) =>
                                    setState(() => _monthDay = value),
                              )
                            else
                              _PickerDropdown(
                                key: const ValueKey('weekday'),
                                width: 150,
                                value: _weekday,
                                items: [
                                  for (
                                    var weekday = DateTime.monday;
                                    weekday <= DateTime.sunday;
                                    weekday++
                                  )
                                    (weekday, _weekdayName(weekday)),
                                ],
                                onChanged: (value) =>
                                    setState(() => _weekday = value),
                              ),
                            Text(
                              'at',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(LucideIcons.clock300, size: 16),
                              label: Text(_timeLabel(_time.hour, _time.minute)),
                              onPressed: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: _time,
                                );
                                if (picked != null) {
                                  setState(() => _time = picked);
                                }
                              },
                            ),
                          ],
                        ),
                      Text(
                        _scheduleSummary,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: AppSpacing.sm,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _valid ? _submit : null,
                    child: const Text('Save'),
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

/// A compact fixed-width dropdown for the schedule detail pickers (weekday,
/// date, and week-of-month).
class _PickerDropdown extends StatelessWidget {
  const _PickerDropdown({
    required super.key,
    required this.width,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final double width;
  final int value;

  /// The selectable values with their display labels.
  final List<(int, String)> items;

  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DropdownButtonFormField<int>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      items: [
        for (final (value, label) in items)
          DropdownMenuItem(value: value, child: Text(label)),
      ],
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    ),
  );
}

/// The instruction editor: a borderless multiline field inside one framed
/// surface, with the agent picker chip docked along its bottom edge.
class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.controller,
    required this.agentChip,
    required this.onChanged,
  });

  final TextEditingController controller;
  final Widget agentChip;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppShape.inner),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            minLines: 4,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'What should the agent do on each run?',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.all(AppSpacing.lg),
            ),
            onChanged: onChanged,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              0,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: agentChip,
          ),
        ],
      ),
    );
  }
}

/// A compact inline agent selector, styled as a quiet chip rather than a
/// full form field so it can live inside the prompt frame.
class _AgentPickerChip extends StatelessWidget {
  const _AgentPickerChip({
    required this.agents,
    required this.selectedId,
    required this.onSelected,
  });

  final List<SavedAgentConfig> agents;
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = agents.firstWhere(
      (a) => a.id == selectedId,
      orElse: () => agents.first,
    );
    return PopupMenuButton<String>(
      tooltip: 'Agent',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final agent in agents)
          CheckedPopupMenuItem(
            value: agent.id,
            checked: agent.id == selectedId,
            child: Text(agent.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.xs,
          children: [
            Icon(
              LucideIcons.bot300,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            Flexible(
              child: Text(
                selected.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              LucideIcons.chevronDown300,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

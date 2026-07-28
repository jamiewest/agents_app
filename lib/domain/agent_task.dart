// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Author name tagging a task prompt that is sent to the agent as a hidden
/// user message.
///
/// The prompt reaches the model as a normal user turn (so it generates a
/// reply on every provider), but the chat view filters this author out of the
/// displayed transcript so the run reads as unprompted agent work. Mirrors the
/// loop-feedback author-name idiom used for background-agent plumbing.
const String taskPromptAuthorName = 'scheduled-task-prompt';

/// When and how often an [AgentTask] runs.
///
/// A schedule computes its own next run time, so the scheduler never needs
/// to know which kind it is. `null` on a task means run once.
sealed class TaskSchedule {
  const TaskSchedule();

  /// The next run time strictly after [after].
  ///
  /// Interval schedules run relative to the previous run; calendar schedules
  /// ([WeeklySchedule], [MonthlyDaySchedule], [MonthlyWeekdaySchedule]) pick
  /// the next matching wall-clock occurrence.
  DateTime nextRunAfter(DateTime after);

  /// Serializes to the map stored under the task record's `schedule` key.
  Map<String, Object?> toRecord();

  /// Reads the schedule out of a full task [record].
  ///
  /// Prefers the `schedule` map; falls back to the legacy top-level
  /// `intervalMinutes` field so existing records keep loading. Returns
  /// `null` (run once) when neither is present or the kind is unknown.
  static TaskSchedule? fromTaskRecord(Map<String, Object?> record) {
    if (record['schedule'] case final Map<String, Object?> map) {
      final hour = map['hour'] as int? ?? 9;
      final minute = map['minute'] as int? ?? 0;
      return switch (map['type']) {
        'interval' => IntervalSchedule(map['minutes']! as int),
        'weekly' => WeeklySchedule(
          weekday: map['weekday']! as int,
          hour: hour,
          minute: minute,
        ),
        'monthlyDay' => MonthlyDaySchedule(
          day: map['day']! as int,
          hour: hour,
          minute: minute,
        ),
        'monthlyWeekday' => MonthlyWeekdaySchedule(
          week: map['week']! as int,
          weekday: map['weekday']! as int,
          hour: hour,
          minute: minute,
        ),
        _ => null,
      };
    }
    return switch (record['intervalMinutes']) {
      final int minutes => IntervalSchedule(minutes),
      _ => null,
    };
  }
}

/// Runs a fixed number of minutes after the previous run.
final class IntervalSchedule extends TaskSchedule {
  /// Creates a schedule repeating every [minutes] minutes.
  const IntervalSchedule(this.minutes);

  /// Minutes between runs.
  final int minutes;

  @override
  DateTime nextRunAfter(DateTime after) =>
      after.add(Duration(minutes: minutes));

  @override
  Map<String, Object?> toRecord() => {'type': 'interval', 'minutes': minutes};

  @override
  bool operator ==(Object other) =>
      other is IntervalSchedule && other.minutes == minutes;

  @override
  int get hashCode => Object.hash('interval', minutes);
}

/// Base for schedules anchored to the calendar at a fixed time of day.
sealed class CalendarSchedule extends TaskSchedule {
  const CalendarSchedule({required this.hour, required this.minute});

  /// Hour of day to run, 0–23.
  final int hour;

  /// Minute within [hour], 0–59.
  final int minute;

  /// Builds a date matching [anchor]'s UTC-ness so scheduler math stays in
  /// one timeline.
  DateTime _at(DateTime anchor, int year, int month, int day) => anchor.isUtc
      ? DateTime.utc(year, month, day, hour, minute)
      : DateTime(year, month, day, hour, minute);
}

/// Runs weekly on a fixed weekday, e.g. every Tuesday at 9:00.
final class WeeklySchedule extends CalendarSchedule {
  /// Creates a weekly schedule on [weekday] ([DateTime.monday] through
  /// [DateTime.sunday]).
  const WeeklySchedule({
    required this.weekday,
    super.hour = 9,
    super.minute = 0,
  });

  /// Day of week, [DateTime.monday] through [DateTime.sunday].
  final int weekday;

  @override
  DateTime nextRunAfter(DateTime after) {
    final candidate = _at(
      after,
      after.year,
      after.month,
      after.day + (weekday - after.weekday + 7) % 7,
    );
    if (candidate.isAfter(after)) return candidate;
    return _at(after, candidate.year, candidate.month, candidate.day + 7);
  }

  @override
  Map<String, Object?> toRecord() => {
    'type': 'weekly',
    'weekday': weekday,
    'hour': hour,
    'minute': minute,
  };

  @override
  bool operator ==(Object other) =>
      other is WeeklySchedule &&
      other.weekday == weekday &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash('weekly', weekday, hour, minute);
}

/// Runs monthly on a fixed date, e.g. the 15th of every month.
final class MonthlyDaySchedule extends CalendarSchedule {
  /// Creates a monthly schedule on day [day] (1–31).
  ///
  /// Months without [day] run on their last day instead, so "the 31st"
  /// means "the end of the month".
  const MonthlyDaySchedule({
    required this.day,
    super.hour = 9,
    super.minute = 0,
  });

  /// Day of month, 1–31.
  final int day;

  @override
  DateTime nextRunAfter(DateTime after) {
    final candidate = _inMonth(after, after.year, after.month);
    if (candidate.isAfter(after)) return candidate;
    return _inMonth(after, after.year, after.month + 1);
  }

  DateTime _inMonth(DateTime after, int year, int month) {
    final lastDay = DateTime(year, month + 1, 0).day;
    return _at(after, year, month, day < lastDay ? day : lastDay);
  }

  @override
  Map<String, Object?> toRecord() => {
    'type': 'monthlyDay',
    'day': day,
    'hour': hour,
    'minute': minute,
  };

  @override
  bool operator ==(Object other) =>
      other is MonthlyDaySchedule &&
      other.day == day &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash('monthlyDay', day, hour, minute);
}

/// Runs monthly on the nth weekday, e.g. the first Tuesday of every month.
final class MonthlyWeekdaySchedule extends CalendarSchedule {
  /// Creates a monthly schedule on the [week]th [weekday] of the month.
  ///
  /// [week] is 1–4, or [lastWeek] for the month's final occurrence.
  const MonthlyWeekdaySchedule({
    required this.week,
    required this.weekday,
    super.hour = 9,
    super.minute = 0,
  });

  /// Sentinel [week] value meaning the last occurrence in the month.
  static const int lastWeek = 5;

  /// Which occurrence within the month: 1–4, or [lastWeek].
  final int week;

  /// Day of week, [DateTime.monday] through [DateTime.sunday].
  final int weekday;

  @override
  DateTime nextRunAfter(DateTime after) {
    final candidate = _inMonth(after, after.year, after.month);
    if (candidate.isAfter(after)) return candidate;
    return _inMonth(after, after.year, after.month + 1);
  }

  DateTime _inMonth(DateTime after, int year, int month) {
    if (week == lastWeek) {
      final last = DateTime(year, month + 1, 0);
      final offset = (last.weekday - weekday + 7) % 7;
      return _at(after, year, month, last.day - offset);
    }
    final first = DateTime(year, month, 1);
    final firstMatch = 1 + (weekday - first.weekday + 7) % 7;
    return _at(after, year, month, firstMatch + (week - 1) * 7);
  }

  @override
  Map<String, Object?> toRecord() => {
    'type': 'monthlyWeekday',
    'week': week,
    'weekday': weekday,
    'hour': hour,
    'minute': minute,
  };

  @override
  bool operator ==(Object other) =>
      other is MonthlyWeekdaySchedule &&
      other.week == week &&
      other.weekday == weekday &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode =>
      Object.hash('monthlyWeekday', week, weekday, hour, minute);
}

/// The lifecycle state of an [AgentTask].
enum AgentTaskStatus {
  /// Waiting for its next run time.
  scheduled,

  /// Currently executing.
  running,

  /// Excluded from scheduling until resumed.
  paused,

  /// The last run failed; still scheduled if recurring.
  failed,

  /// A one-shot task that finished.
  completed,
}

/// Scheduled or background work owned by an agent, optionally on behalf of
/// a channel.
///
/// Runs execute in a dedicated conversation (`taskConversationId`) so the
/// work has durable, inspectable history like any other conversation.
class AgentTask {
  /// Creates an [AgentTask].
  const AgentTask({
    required this.id,
    required this.title,
    required this.prompt,
    required this.agentId,
    required this.status,
    required this.createdAt,
    this.channelId,
    this.schedule,
    this.nextRunAt,
    this.lastRunAt,
  });

  /// Stable task id.
  final String id;

  /// Short human-readable name.
  final String title;

  /// The instruction sent to the agent on each run.
  final String prompt;

  /// The configured agent responsible for the task.
  final String agentId;

  /// The channel this task belongs to, when any.
  final String? channelId;

  /// When the task repeats; `null` means run once.
  final TaskSchedule? schedule;

  /// Lifecycle state.
  final AgentTaskStatus status;

  /// When the task should next run.
  final DateTime? nextRunAt;

  /// When the task last ran.
  final DateTime? lastRunAt;

  /// When the task was created.
  final DateTime createdAt;

  /// The conversation task runs execute in.
  String get taskConversationId => 'task-$id';

  /// Returns a copy with the given fields replaced.
  AgentTask copyWith({
    AgentTaskStatus? status,
    DateTime? nextRunAt,
    DateTime? lastRunAt,
  }) => AgentTask(
    id: id,
    title: title,
    prompt: prompt,
    agentId: agentId,
    channelId: channelId,
    schedule: schedule,
    status: status ?? this.status,
    nextRunAt: nextRunAt ?? this.nextRunAt,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    createdAt: createdAt,
  );

  /// Serializes to a `RecordStore`-compatible map.
  Map<String, Object?> toRecord() => {
    'title': title,
    'prompt': prompt,
    'agentId': agentId,
    if (channelId != null) 'channelId': channelId,
    ...switch (schedule) {
      null => const <String, Object?>{},
      IntervalSchedule(:final minutes) => {'intervalMinutes': minutes},
      final calendar => {'schedule': calendar.toRecord()},
    },
    'status': status.name,
    if (nextRunAt != null) 'nextRunAt': nextRunAt!.toUtc().toIso8601String(),
    if (lastRunAt != null) 'lastRunAt': lastRunAt!.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Reconstructs an [AgentTask] from a stored record.
  static AgentTask fromRecord(String id, Map<String, Object?> record) =>
      AgentTask(
        id: id,
        title: record['title']! as String,
        prompt: record['prompt']! as String,
        agentId: record['agentId']! as String,
        channelId: record['channelId'] as String?,
        schedule: TaskSchedule.fromTaskRecord(record),
        status: AgentTaskStatus.values.byName(record['status']! as String),
        nextRunAt: switch (record['nextRunAt']) {
          final String value => DateTime.parse(value),
          _ => null,
        },
        lastRunAt: switch (record['lastRunAt']) {
          final String value => DateTime.parse(value),
          _ => null,
        },
        createdAt: DateTime.parse(record['createdAt']! as String),
      );
}

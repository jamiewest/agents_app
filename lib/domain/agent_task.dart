// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

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
    this.intervalMinutes,
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

  /// Minutes between runs; `null` means run once.
  final int? intervalMinutes;

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
    intervalMinutes: intervalMinutes,
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
    if (intervalMinutes != null) 'intervalMinutes': intervalMinutes,
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
        intervalMinutes: record['intervalMinutes'] as int?,
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

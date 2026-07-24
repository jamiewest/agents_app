// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

/// Field names for the durable per-run ledger.
///
/// Deliberately carries no token counts: tokens live in `usage_records`
/// (see [UsageRecords]), one row per model call, and are joined back to a
/// run through that collection's run id. Accumulating them here as well
/// would create a second total that can silently disagree with the first.
abstract final class AgentRunRecords {
  /// The [RecordStore] collection holding run records.
  static const String collection = 'agent_runs';

  /// The saved agent configuration that ran.
  static const String agentIdField = 'agentId';

  /// The agent's display name at the time of the run.
  static const String agentNameField = 'agentName';

  /// The configured model the agent ran on, when known.
  static const String modelIdField = 'modelId';

  /// The model's display label at the time of the run.
  static const String modelNameField = 'modelName';

  /// The model source backing the run, when known.
  static const String sourceIdField = 'sourceId';

  /// The source's display name at the time of the run.
  static const String sourceNameField = 'sourceName';

  /// What initiated the run; an [AgentRunOrigin] name.
  static const String originField = 'origin';

  /// The conversation the run belonged to, when any.
  static const String conversationIdField = 'conversationId';

  /// The scheduled task that triggered the run, when any.
  static const String taskIdField = 'taskId';

  /// The run's terminal (or in-flight) state; an [AgentRunStatus] name.
  static const String statusField = 'status';

  /// ISO-8601 UTC timestamp of when the run started.
  static const String startedAtField = 'startedAt';

  /// ISO-8601 UTC timestamp of when the run finished, or null while running.
  static const String endedAtField = 'endedAt';

  /// Number of model calls the run made, tool-loop sub-calls included.
  static const String modelCallsField = 'modelCalls';
}

/// What initiated an agent run.
enum AgentRunOrigin {
  /// A user turn in an interactive chat.
  chat,

  /// A scheduled task execution.
  scheduledTask,

  /// An inbound request to a hosted (A2A) agent.
  hostedRequest,
}

/// The state of an agent run.
///
/// [succeeded] and [failed] are decided by whether the run's stream
/// completed or threw. A run the user cancels mid-stream completes its
/// stream normally and so counts as [succeeded] — cancellation is not a
/// failure of the agent. A tool that errors but which the agent recovers
/// from is likewise not a failure; only an error that terminates the run
/// is. [interrupted] is never written by a running app: it is applied at
/// startup to rows left [running] by a crash or a force-quit.
enum AgentRunStatus {
  /// The run is in flight.
  running,

  /// The run completed without throwing.
  succeeded,

  /// The run terminated with an error.
  failed,

  /// The app stopped before the run finished.
  interrupted,
}

/// One agent invocation: a chat turn, a scheduled execution, or a hosted
/// request.
class AgentRunRecord {
  /// Creates an [AgentRunRecord].
  const AgentRunRecord({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.origin,
    required this.status,
    required this.startedAt,
    this.modelId,
    this.modelName,
    this.sourceId,
    this.sourceName,
    this.conversationId,
    this.taskId,
    this.endedAt,
    this.modelCalls = 0,
  });

  /// Decodes a record previously written by [toJson].
  factory AgentRunRecord.fromJson(String id, Map<String, Object?> value) =>
      AgentRunRecord(
        id: id,
        agentId: value[AgentRunRecords.agentIdField] as String? ?? 'unknown',
        agentName:
            value[AgentRunRecords.agentNameField] as String? ?? 'Unknown agent',
        modelId: value[AgentRunRecords.modelIdField] as String?,
        modelName: value[AgentRunRecords.modelNameField] as String?,
        sourceId: value[AgentRunRecords.sourceIdField] as String?,
        sourceName: value[AgentRunRecords.sourceNameField] as String?,
        origin: _originFromName(value[AgentRunRecords.originField] as String?),
        conversationId: value[AgentRunRecords.conversationIdField] as String?,
        taskId: value[AgentRunRecords.taskIdField] as String?,
        status: _statusFromName(value[AgentRunRecords.statusField] as String?),
        startedAt:
            DateTime.tryParse(
              value[AgentRunRecords.startedAtField] as String? ?? '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        endedAt: DateTime.tryParse(
          value[AgentRunRecords.endedAtField] as String? ?? '',
        ),
        modelCalls: value[AgentRunRecords.modelCallsField] as int? ?? 0,
      );

  /// The stable run id.
  final String id;

  /// The saved agent configuration that ran.
  final String agentId;

  /// The agent's display name when the run started.
  ///
  /// Snapshotted so a run stays readable after the agent is renamed or
  /// deleted.
  final String agentName;

  /// The configured model id, when known.
  final String? modelId;

  /// The model's display label when the run started.
  final String? modelName;

  /// The model source id, when known.
  final String? sourceId;

  /// The source's display name when the run started.
  final String? sourceName;

  /// What initiated the run.
  final AgentRunOrigin origin;

  /// The conversation the run belonged to, when any.
  final String? conversationId;

  /// The scheduled task that triggered the run, when any.
  final String? taskId;

  /// The run's state.
  final AgentRunStatus status;

  /// When the run started.
  final DateTime startedAt;

  /// When the run finished, or null while it is still running.
  final DateTime? endedAt;

  /// Model calls made during the run, tool-loop sub-calls included.
  final int modelCalls;

  /// How long the run took, or null while it is still running.
  Duration? get duration => endedAt?.difference(startedAt);

  /// Whether the run is still in flight.
  bool get isRunning => status == AgentRunStatus.running;

  /// Encodes this record for the [RecordStore].
  Map<String, Object?> toJson() => {
    AgentRunRecords.agentIdField: agentId,
    AgentRunRecords.agentNameField: agentName,
    if (modelId != null) AgentRunRecords.modelIdField: modelId,
    if (modelName != null) AgentRunRecords.modelNameField: modelName,
    if (sourceId != null) AgentRunRecords.sourceIdField: sourceId,
    if (sourceName != null) AgentRunRecords.sourceNameField: sourceName,
    AgentRunRecords.originField: origin.name,
    if (conversationId != null)
      AgentRunRecords.conversationIdField: conversationId,
    if (taskId != null) AgentRunRecords.taskIdField: taskId,
    AgentRunRecords.statusField: status.name,
    AgentRunRecords.startedAtField: startedAt.toUtc().toIso8601String(),
    if (endedAt != null)
      AgentRunRecords.endedAtField: endedAt!.toUtc().toIso8601String(),
    AgentRunRecords.modelCallsField: modelCalls,
  };

  /// Returns a copy with the given fields replaced.
  AgentRunRecord copyWith({
    AgentRunStatus? status,
    DateTime? endedAt,
    int? modelCalls,
  }) => AgentRunRecord(
    id: id,
    agentId: agentId,
    agentName: agentName,
    modelId: modelId,
    modelName: modelName,
    sourceId: sourceId,
    sourceName: sourceName,
    origin: origin,
    conversationId: conversationId,
    taskId: taskId,
    status: status ?? this.status,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    modelCalls: modelCalls ?? this.modelCalls,
  );

  static AgentRunOrigin _originFromName(String? name) =>
      AgentRunOrigin.values.firstWhere(
        (origin) => origin.name == name,
        orElse: () => AgentRunOrigin.chat,
      );

  static AgentRunStatus _statusFromName(String? name) =>
      AgentRunStatus.values.firstWhere(
        (status) => status.name == name,
        orElse: () => AgentRunStatus.interrupted,
      );
}

/// A live run, held by whoever started it.
///
/// The run is written once when it begins (so a crash leaves a `running`
/// row for [AgentRunTelemetryStore.recoverInterrupted] to find) and once
/// when it ends. Model calls are counted in memory in between rather than
/// through a read-modify-write per call.
class AgentRunHandle {
  AgentRunHandle._(this._store, this._record);

  final AgentRunTelemetryStore _store;
  AgentRunRecord _record;
  bool _finished = false;

  /// The run's id, as stamped onto its usage records.
  String get id => _record.id;

  /// Counts one model call against the run.
  void countModelCall() {
    if (_finished) return;
    _record = _record.copyWith(modelCalls: _record.modelCalls + 1);
  }

  /// Marks the run succeeded.
  Future<void> succeed() => _finish(AgentRunStatus.succeeded);

  /// Marks the run failed.
  Future<void> fail() => _finish(AgentRunStatus.failed);

  Future<void> _finish(AgentRunStatus status) async {
    if (_finished) return;
    _finished = true;
    _record = _record.copyWith(status: status, endedAt: DateTime.now());
    await _store._write(_record);
  }
}

/// A durable ledger of agent runs.
///
/// Records run-level facts only — identity, origin, status, timing, and
/// model-call count. Token totals come from `usage_records`, joined on the
/// run id that [AgentRunScope] stamps onto each usage row.
class AgentRunTelemetryStore {
  /// Creates an [AgentRunTelemetryStore] over [records].
  AgentRunTelemetryStore(this._records);

  final RecordStore _records;

  /// Starts a run and returns a handle for finishing it.
  ///
  /// The `running` row is written before the handle is returned so an
  /// abrupt termination leaves evidence the run existed.
  Future<AgentRunHandle> begin({
    required String agentId,
    required String agentName,
    required AgentRunOrigin origin,
    String? modelId,
    String? modelName,
    String? sourceId,
    String? sourceName,
    String? conversationId,
    String? taskId,
  }) async {
    final record = AgentRunRecord(
      id: newRunId(),
      agentId: agentId,
      agentName: agentName,
      modelId: modelId,
      modelName: modelName,
      sourceId: sourceId,
      sourceName: sourceName,
      origin: origin,
      conversationId: conversationId,
      taskId: taskId,
      status: AgentRunStatus.running,
      startedAt: DateTime.now(),
    );
    await _write(record);
    return AgentRunHandle._(this, record);
  }

  /// Loads runs, newest first.
  Future<List<AgentRunRecord>> list({
    DateTime? since,
    String? agentId,
    int? limit,
  }) async {
    final records = await _records.query(
      AgentRunRecords.collection,
      query: RecordQuery(
        equals: {AgentRunRecords.agentIdField: ?agentId},
        orderBy: AgentRunRecords.startedAtField,
        descending: true,
      ),
    );
    final runs = [
      for (final record in records)
        AgentRunRecord.fromJson(record.id, record.value),
    ];
    final filtered = since == null
        ? runs
        : [
            for (final run in runs)
              if (run.startedAt.isAfter(since)) run,
          ];
    return limit == null || filtered.length <= limit
        ? filtered
        : filtered.sublist(0, limit);
  }

  /// Watches every run, newest first.
  Stream<List<AgentRunRecord>> watch() => _records
      .watch(
        AgentRunRecords.collection,
        query: const RecordQuery(
          orderBy: AgentRunRecords.startedAtField,
          descending: true,
        ),
      )
      .map(
        (records) => [
          for (final record in records)
            AgentRunRecord.fromJson(record.id, record.value),
        ],
      );

  /// Rewrites rows left `running` by a previous launch as `interrupted`.
  ///
  /// Call once during startup, before any new run can begin — a run started
  /// after this sweep would otherwise be swept as interrupted while it is
  /// still legitimately in flight.
  ///
  /// Returns the number of records recovered.
  Future<int> recoverInterrupted() async {
    final stale = await _records.query(
      AgentRunRecords.collection,
      query: const RecordQuery(
        equals: {AgentRunRecords.statusField: 'running'},
      ),
    );
    for (final record in stale) {
      final run = AgentRunRecord.fromJson(record.id, record.value);
      await _write(
        run.copyWith(
          status: AgentRunStatus.interrupted,
          // The end time is unknown; the start time keeps the row's
          // duration at zero rather than inventing one.
          endedAt: run.startedAt,
        ),
      );
    }
    return stale.length;
  }

  /// Deletes runs that started before [cutoff].
  ///
  /// The ledger is otherwise unbounded, and a busy agent produces a run per
  /// turn. Callers trim on a schedule rather than relying on app reset.
  Future<void> trimBefore(DateTime cutoff) async {
    final runs = await _records.query(AgentRunRecords.collection);
    for (final record in runs) {
      final run = AgentRunRecord.fromJson(record.id, record.value);
      if (run.startedAt.isBefore(cutoff)) {
        await _records.delete(AgentRunRecords.collection, record.id);
      }
    }
  }

  Future<void> _write(AgentRunRecord record) async {
    try {
      await _records.put(
        AgentRunRecords.collection,
        record.id,
        record.toJson(),
      );
    } catch (error, stackTrace) {
      // Telemetry must never fail a run.
      developer.log(
        'Failed to persist agent run "${record.id}".',
        name: 'agents_app.telemetry',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static final Random _random = Random.secure();

  /// Generates a time-ordered, collision-resistant run id.
  static String newRunId() {
    final suffix = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }
}

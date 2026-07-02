// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

import '../domain/agent_task.dart';

/// Persists [AgentTask] records.
class AgentTaskStore {
  /// Creates an [AgentTaskStore] over [records].
  AgentTaskStore(this._records);

  /// The record collection holding tasks.
  static const String collection = 'agent_tasks';

  final RecordStore _records;

  /// Generates a unique task id.
  String newTaskId() {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  /// Saves [task].
  Future<void> save(AgentTask task) =>
      _records.put(collection, task.id, task.toRecord());

  /// Loads the task with [id], or `null` when missing.
  Future<AgentTask?> get(String id) async {
    final record = await _records.get(collection, id);
    return record == null ? null : AgentTask.fromRecord(id, record);
  }

  /// Deletes the task with [id].
  Future<void> delete(String id) => _records.delete(collection, id);

  /// Watches all tasks, newest first.
  Stream<List<AgentTask>> watchAll() => _records
      .watch(
        collection,
        query: const RecordQuery(orderBy: 'createdAt', descending: true),
      )
      .map(
        (records) => [
          for (final record in records)
            AgentTask.fromRecord(record.id, record.value),
        ],
      );

  /// Lists tasks whose next run is due at or before [now].
  Future<List<AgentTask>> listDue(DateTime now) async {
    final records = await _records.query(
      collection,
      query: const RecordQuery(
        equals: {'status': 'scheduled'},
        orderBy: 'nextRunAt',
      ),
    );
    return [
      for (final record in records)
        if (AgentTask.fromRecord(record.id, record.value) case final task
            when task.nextRunAt != null && !task.nextRunAt!.isAfter(now))
          task,
    ];
  }
}

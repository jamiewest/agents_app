// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

import 'workflow_spec.dart';

/// Persists [WorkflowSpec]s in the app's record store.
class WorkflowSpecStore {
  /// Creates a [WorkflowSpecStore] over [records].
  WorkflowSpecStore(this._records);

  /// The record collection holding workflow specs.
  static const String collection = 'workflow_specs';

  final RecordStore _records;

  /// Generates a unique workflow id.
  String newId() {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return 'wf-${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  /// Saves [spec], stamping its update time.
  Future<void> save(WorkflowSpec spec) => _records.put(collection, spec.id, {
    ...spec.toRecord(),
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });

  /// Loads the spec with [id], or null when missing.
  Future<WorkflowSpec?> get(String id) async {
    final record = await _records.get(collection, id);
    return record == null ? null : WorkflowSpec.fromRecord(id, record);
  }

  /// Deletes the spec with [id].
  Future<void> delete(String id) => _records.delete(collection, id);

  /// Watches all saved specs, most recently updated first.
  Stream<List<WorkflowSpec>> watchAll() => _records
      .watch(
        collection,
        query: const RecordQuery(orderBy: 'updatedAt', descending: true),
      )
      .map(
        (records) => [
          for (final record in records)
            WorkflowSpec.fromRecord(record.id, record.value),
        ],
      );
}

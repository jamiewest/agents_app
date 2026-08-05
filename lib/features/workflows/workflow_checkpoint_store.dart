// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:agents_flutter/agents_flutter.dart';

/// Persists workflow run [Checkpoint]s in the app's record store, so a
/// saved workflow's latest run can be replayed after an app restart.
///
/// Every run of a saved workflow uses the spec id as its session id, and
/// the engine derives checkpoint ids from the session id and superstep
/// number — so a new run of the same workflow overwrites the previous
/// trail record by record. [clearSession] removes the remainder before a
/// fresh run, keeping exactly one trail per workflow.
class WorkflowCheckpointStore implements CheckpointStore {
  /// Creates a [WorkflowCheckpointStore] over [records].
  WorkflowCheckpointStore(this._records);

  /// The record collection holding checkpoint trails.
  static const String collection = 'workflow_checkpoints';

  final RecordStore _records;

  /// A checkpoint manager recording into this store under [sessionId].
  CheckpointManagerImpl managerFor(String sessionId) =>
      CheckpointManagerImpl(this, sessionId: sessionId);

  /// Deletes every checkpoint recorded under [sessionId].
  Future<void> clearSession(String sessionId) => _records.deleteWhere(
    collection,
    RecordQuery(equals: {'sessionId': sessionId}),
  );

  @override
  Future<void> writeCheckpointAsync(Checkpoint checkpoint) => _records.put(
    collection,
    checkpoint.info.checkpointId,
    checkpoint.toJson(),
  );

  @override
  Future<Checkpoint?> readCheckpointAsync(String checkpointId) async {
    final record = await _records.get(collection, checkpointId);
    return record == null ? null : Checkpoint.fromJson(record);
  }

  @override
  Future<List<Checkpoint>> listCheckpointsAsync({String? sessionId}) async {
    final records = await _records.query(
      collection,
      query: sessionId == null
          ? null
          : RecordQuery(equals: {'sessionId': sessionId}),
    );
    final checkpoints = [
      for (final record in records) Checkpoint.fromJson(record.value),
    ];
    checkpoints.sort((left, right) {
      final bySuperStep = left.superStep.compareTo(right.superStep);
      return bySuperStep != 0
          ? bySuperStep
          : left.info.checkpointId.compareTo(right.info.checkpointId);
    });
    return checkpoints;
  }

  @override
  Future<bool> deleteCheckpointAsync(String checkpointId) async {
    if (await _records.get(collection, checkpointId) == null) return false;
    await _records.delete(collection, checkpointId);
    return true;
  }
}

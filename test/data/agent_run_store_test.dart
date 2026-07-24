// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<AgentRunHandle> begin(
    AgentRunTelemetryStore store, {
    String agentId = 'agent-1',
    String agentName = 'Researcher',
    AgentRunOrigin origin = AgentRunOrigin.chat,
    String? conversationId = 'conv-1',
    String? taskId,
  }) => store.begin(
    agentId: agentId,
    agentName: agentName,
    origin: origin,
    conversationId: conversationId,
    taskId: taskId,
    modelId: 'model-1',
    modelName: 'Claude Opus 4.8',
    sourceId: 'source-1',
    sourceName: 'Anthropic',
  );

  group('AgentRunTelemetryStore', () {
    test('writes a running row before the handle is returned', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());

      final handle = await begin(store);

      final run = (await store.list()).single;
      expect(run.id, handle.id);
      expect(run.status, AgentRunStatus.running);
      expect(run.isRunning, isTrue);
      expect(run.endedAt, isNull);
      expect(run.duration, isNull);
      expect(run.agentName, 'Researcher');
      expect(run.modelName, 'Claude Opus 4.8');
      expect(run.sourceName, 'Anthropic');
      expect(run.origin, AgentRunOrigin.chat);
      expect(run.conversationId, 'conv-1');
    });

    test('succeed finalizes status, end time, and model calls', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final handle = await begin(store);

      handle
        ..countModelCall()
        ..countModelCall()
        ..countModelCall();
      await handle.succeed();

      final run = (await store.list()).single;
      expect(run.status, AgentRunStatus.succeeded);
      expect(run.modelCalls, 3);
      expect(run.endedAt, isNotNull);
      expect(run.duration, isNotNull);
      expect(run.isRunning, isFalse);
    });

    test('fail records a failed terminal state', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final handle = await begin(store);

      await handle.fail();

      expect((await store.list()).single.status, AgentRunStatus.failed);
    });

    test('finishing twice keeps the first outcome', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final handle = await begin(store);

      await handle.succeed();
      await handle.fail();
      handle.countModelCall();

      final run = (await store.list()).single;
      expect(run.status, AgentRunStatus.succeeded);
      expect(run.modelCalls, 0);
    });

    test('tracks concurrent runs independently', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());

      final first = await begin(store, agentId: 'agent-1');
      final second = await begin(store, agentId: 'agent-2');
      first
        ..countModelCall()
        ..countModelCall();
      second.countModelCall();
      await second.fail();
      await first.succeed();

      final runs = await store.list();
      expect(runs, hasLength(2));
      expect(first.id, isNot(second.id));
      final byId = {for (final run in runs) run.id: run};
      expect(byId[first.id]!.status, AgentRunStatus.succeeded);
      expect(byId[first.id]!.modelCalls, 2);
      expect(byId[second.id]!.status, AgentRunStatus.failed);
      expect(byId[second.id]!.modelCalls, 1);
    });

    test('recoverInterrupted rewrites only rows left running', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final finished = await begin(store);
      await finished.succeed();
      final stranded = await begin(store);

      final recovered = await store.recoverInterrupted();

      expect(recovered, 1);
      final byId = {for (final run in await store.list()) run.id: run};
      expect(byId[finished.id]!.status, AgentRunStatus.succeeded);
      expect(byId[stranded.id]!.status, AgentRunStatus.interrupted);
      // No end time is known, so the run reports zero duration rather than
      // an invented one.
      expect(byId[stranded.id]!.duration, Duration.zero);
    });

    test('recoverInterrupted is a no-op on a clean ledger', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      await (await begin(store)).succeed();

      expect(await store.recoverInterrupted(), 0);
    });

    test('lists newest first and filters by agent and time', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final first = await begin(store, agentId: 'agent-1');
      await first.succeed();
      final cutoff = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await begin(store, agentId: 'agent-2');
      await second.succeed();

      final all = await store.list();
      expect(all.map((run) => run.id), [second.id, first.id]);
      expect((await store.list(agentId: 'agent-1')).map((run) => run.id), [
        first.id,
      ]);
      expect((await store.list(since: cutoff)).map((run) => run.id), [
        second.id,
      ]);
      expect(await store.list(limit: 1), hasLength(1));
    });

    test('round-trips origin and task id for scheduled runs', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());

      await begin(
        store,
        origin: AgentRunOrigin.scheduledTask,
        taskId: 'task-9',
      );

      final run = (await store.list()).single;
      expect(run.origin, AgentRunOrigin.scheduledTask);
      expect(run.taskId, 'task-9');
    });

    test('round-trips hosted runs with no conversation', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());

      await begin(
        store,
        origin: AgentRunOrigin.hostedRequest,
        conversationId: null,
      );

      final run = (await store.list()).single;
      expect(run.origin, AgentRunOrigin.hostedRequest);
      expect(run.conversationId, isNull);
    });

    test('trimBefore drops older runs only', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final old = await begin(store);
      await old.succeed();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final cutoff = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final kept = await begin(store);
      await kept.succeed();

      await store.trimBefore(cutoff);

      expect((await store.list()).map((run) => run.id), [kept.id]);
    });

    test('watch emits the ledger as runs begin and finish', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());
      final emissions = <List<AgentRunRecord>>[];
      final sub = store.watch().listen(emissions.add);
      await pumpEventQueue();

      final handle = await begin(store);
      await pumpEventQueue();
      await handle.succeed();
      await pumpEventQueue();

      await sub.cancel();
      expect(emissions.first, isEmpty);
      expect(emissions.last.single.status, AgentRunStatus.succeeded);
    });

    test('decodes an unrecognized status as interrupted', () {
      final run = AgentRunRecord.fromJson('run-1', const {
        AgentRunRecords.agentIdField: 'agent-1',
        AgentRunRecords.agentNameField: 'Researcher',
        AgentRunRecords.statusField: 'from-a-future-version',
        AgentRunRecords.startedAtField: '2026-07-23T12:00:00.000Z',
      });

      expect(run.status, AgentRunStatus.interrupted);
      expect(run.origin, AgentRunOrigin.chat);
    });

    test('keeps snapshotted labels for deleted resources', () async {
      final store = AgentRunTelemetryStore(InMemoryRecordStore());

      await store.begin(
        agentId: 'deleted-agent',
        agentName: 'Retired assistant',
        origin: AgentRunOrigin.chat,
        modelName: 'Retired model',
      );

      final run = (await store.list()).single;
      expect(run.agentName, 'Retired assistant');
      expect(run.modelName, 'Retired model');
    });
  });
}

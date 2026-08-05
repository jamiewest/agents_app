// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:agents_app/features/workflows/role_agent.dart';
import 'package:agents_app/features/workflows/workflow_checkpoint_store.dart';
import 'package:agents_app/features/workflows/workflow_launcher.dart';
import 'package:agents_app/features/workflows/workflow_run_controller.dart';
import 'package:agents_app/features/workflows/workflow_spec.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_agent.dart';

Future<void> waitFor(
  WorkflowRunController controller,
  bool Function() predicate,
) async {
  if (predicate()) return;
  final completer = Completer<void>();
  void listener() {
    if (predicate() && !completer.isCompleted) completer.complete();
  }

  controller.addListener(listener);
  try {
    await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(listener);
  }
}

Future<AIAgent> buildScriptedAgent(WorkflowNodeSpec node) async => RoleAgent(
  ScriptedAgent(
    name: 'inner',
    onRun: (messages, options) => assistantResponse('${node.label}-reply'),
  ),
  role: node.label,
  roleInstructions: node.instructions,
);

Checkpoint checkpointFor(String sessionId, int superStep) => Checkpoint(
  info: CheckpointInfo('$sessionId-step-$superStep'),
  sessionId: sessionId,
  superStep: superStep,
);

void main() {
  setUpAll(registerWorkflowWireConverters);

  group('WorkflowCheckpointStore', () {
    test(
      'trail survives a store re-open and replays after "restart"',
      () async {
        final records = InMemoryRecordStore();
        final spec = WorkflowSpec.fromTemplate(
          'wf-persist',
          WorkflowTemplate.pipeline,
        );

        final compiled = await compileWorkflowSpec(
          spec,
          buildAgent: buildScriptedAgent,
        );
        final first = WorkflowRunController(
          workflow: compiled.workflow,
          encodeResponse: compiled.encodeResponse,
          checkpoints: WorkflowCheckpointStore(records).managerFor(spec.id),
        );
        await first.start('hello');
        await waitFor(first, () => first.isFinished);
        expect(first.runError, isNull);
        expect(first.checkpointList, isNotEmpty);
        first.dispose();

        // A fresh store over the same records simulates an app restart.
        final reopened = WorkflowCheckpointStore(records);
        final saved = await reopened.listCheckpointsAsync(sessionId: spec.id);
        expect(saved, isNotEmpty);
        expect(saved.first.sessionId, spec.id);

        final recompiled = await compileWorkflowSpec(
          spec,
          buildAgent: buildScriptedAgent,
        );
        final replay = WorkflowRunController(
          workflow: recompiled.workflow,
          encodeResponse: recompiled.encodeResponse,
          checkpoints: reopened.managerFor(spec.id),
        );
        await replay.startFromCheckpoint(saved.first.info);
        await waitFor(replay, () => replay.isFinished);

        expect(replay.runError, isNull);
        expect(replay.finalOutput.map((m) => m.text), contains('Editor-reply'));
        replay.dispose();
        records.dispose();
      },
    );

    test('lists in superstep order and scopes by session', () async {
      final store = WorkflowCheckpointStore(InMemoryRecordStore());
      await store.writeCheckpointAsync(checkpointFor('wf-a', 10));
      await store.writeCheckpointAsync(checkpointFor('wf-a', 2));
      await store.writeCheckpointAsync(checkpointFor('wf-a', 1));
      await store.writeCheckpointAsync(checkpointFor('wf-b', 1));

      final trail = await store.listCheckpointsAsync(sessionId: 'wf-a');
      expect([for (final c in trail) c.superStep], [1, 2, 10]);
      expect(await store.listCheckpointsAsync(), hasLength(4));
    });

    test('clearSession removes only that workflow\'s trail', () async {
      final store = WorkflowCheckpointStore(InMemoryRecordStore());
      await store.writeCheckpointAsync(checkpointFor('wf-a', 1));
      await store.writeCheckpointAsync(checkpointFor('wf-b', 1));

      await store.clearSession('wf-a');
      expect(await store.listCheckpointsAsync(sessionId: 'wf-a'), isEmpty);
      expect(await store.listCheckpointsAsync(sessionId: 'wf-b'), hasLength(1));
    });

    test('read and delete round-trip by checkpoint id', () async {
      final store = WorkflowCheckpointStore(InMemoryRecordStore());
      await store.writeCheckpointAsync(checkpointFor('wf-a', 1));

      final restored = await store.readCheckpointAsync('wf-a-step-1');
      expect(restored?.superStep, 1);
      expect(await store.deleteCheckpointAsync('wf-a-step-1'), isTrue);
      expect(await store.deleteCheckpointAsync('wf-a-step-1'), isFalse);
      expect(await store.readCheckpointAsync('wf-a-step-1'), isNull);
    });
  });
}

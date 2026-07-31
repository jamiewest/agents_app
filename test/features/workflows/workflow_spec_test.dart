// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:agents_app/features/workflows/role_agent.dart';
import 'package:agents_app/features/workflows/workflow_launcher.dart';
import 'package:agents_app/features/workflows/workflow_run_controller.dart';
import 'package:agents_app/features/workflows/workflow_spec.dart';
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

void main() {
  setUpAll(registerWorkflowWireConverters);

  group('WorkflowSpec', () {
    test('starter spec validates and round-trips through a record', () {
      final spec = WorkflowSpec.starter('w1');
      expect(spec.validate(), isEmpty);

      final restored = WorkflowSpec.fromRecord('w1', spec.toRecord());
      expect(restored.name, spec.name);
      expect(restored.nodes.length, spec.nodes.length);
      expect(restored.edges.length, spec.edges.length);
      expect(restored.nodes.first.kind, WorkflowNodeKind.agent);
      expect(restored.nodes.first.x, spec.nodes.first.x);
      expect(restored.validate(), isEmpty);
    });

    test('validation catches broken graphs', () {
      final spec = WorkflowSpec.starter('w1');

      // Remove the output: no terminal node, agent leads nowhere.
      spec.nodes.removeWhere((n) => n.kind == WorkflowNodeKind.output);
      spec.edges.clear();
      expect(spec.validate(), isNotEmpty);

      // Duplicate labels.
      final duplicated = WorkflowSpec.starter('w2');
      duplicated.nodes.first.label = 'Output';
      expect(
        duplicated.validate().join(),
        contains('unique'),
      );

      // A cycle.
      final cyclic = WorkflowSpec.starter('w3');
      cyclic.nodes.add(
        WorkflowNodeSpec(
          id: 'n3',
          kind: WorkflowNodeKind.agent,
          label: 'Loop',
        ),
      );
      cyclic.edges.addAll(const [
        WorkflowEdgeSpec('n1', 'n3'),
        WorkflowEdgeSpec('n3', 'n1'),
      ]);
      expect(cyclic.validate().join(), contains('cycle'));

      // Multiple incoming edges on a non-merge node.
      final fanIn = WorkflowSpec(
        id: 'w4',
        name: 'bad fan-in',
        nodes: [
          WorkflowNodeSpec(
            id: 'a',
            kind: WorkflowNodeKind.agent,
            label: 'A',
          ),
          WorkflowNodeSpec(
            id: 'b',
            kind: WorkflowNodeKind.agent,
            label: 'B',
          ),
          WorkflowNodeSpec(
            id: 'c',
            kind: WorkflowNodeKind.agent,
            label: 'C',
          ),
          WorkflowNodeSpec(
            id: 'out',
            kind: WorkflowNodeKind.output,
            label: 'Out',
          ),
        ],
        edges: const [
          WorkflowEdgeSpec('a', 'b'),
          WorkflowEdgeSpec('a', 'c'),
          WorkflowEdgeSpec('b', 'out'),
          WorkflowEdgeSpec('c', 'out'),
        ],
      );
      expect(fanIn.validate().join(), contains('Merge'));
    });

    test('compiled sequential spec with a review gate runs end to end',
        () async {
      final spec = WorkflowSpec(
        id: 'w5',
        name: 'Reviewed pipeline',
        nodes: [
          WorkflowNodeSpec(
            id: 'n1',
            kind: WorkflowNodeKind.agent,
            label: 'Drafter',
          ),
          WorkflowNodeSpec(
            id: 'n2',
            kind: WorkflowNodeKind.review,
            label: 'Check with me',
          ),
          WorkflowNodeSpec(
            id: 'n3',
            kind: WorkflowNodeKind.agent,
            label: 'Editor',
          ),
          WorkflowNodeSpec(
            id: 'n4',
            kind: WorkflowNodeKind.output,
            label: 'Result',
          ),
        ],
        edges: const [
          WorkflowEdgeSpec('n1', 'n2'),
          WorkflowEdgeSpec('n2', 'n3'),
          WorkflowEdgeSpec('n3', 'n4'),
        ],
      );
      expect(spec.validate(), isEmpty);

      final compiled = await compileWorkflowSpec(
        spec,
        buildAgent: buildScriptedAgent,
      );
      final controller = WorkflowRunController(
        workflow: compiled.workflow,
        encodeResponse: compiled.encodeResponse,
      );

      await controller.start('hello');
      await waitFor(
        controller,
        () => controller.status == RunStatus.pendingRequests,
      );
      final request = controller.pendingRequests.single;
      expect(request.port.id, 'Check with me');
      expect('${request.request}', contains('Drafter-reply'));

      await controller.respond(request, 'looks good');
      await waitFor(controller, () => controller.isFinished);

      expect(controller.runError, isNull);
      expect(
        controller.finalOutput.map((m) => m.text),
        contains('Editor-reply'),
      );
      controller.dispose();
    });

    test('every template produces a valid, compilable spec', () async {
      for (final template in WorkflowTemplate.values) {
        final spec = WorkflowSpec.fromTemplate('t-${template.name}', template);
        expect(spec.validate(), isEmpty, reason: template.name);
        final compiled = await compileWorkflowSpec(
          spec,
          buildAgent: buildScriptedAgent,
        );
        expect(compiled.workflow.name, spec.name);
      }
    });

    test('checkpointed run records checkpoints and replays from one',
        () async {
      final spec = WorkflowSpec.fromTemplate('w7', WorkflowTemplate.pipeline);
      final manager = InMemoryCheckpointManager(sessionId: 'w7');

      final compiled = await compileWorkflowSpec(
        spec,
        buildAgent: buildScriptedAgent,
      );
      final first = WorkflowRunController(
        workflow: compiled.workflow,
        encodeResponse: compiled.encodeResponse,
        checkpoints: manager,
      );
      await first.start('hello');
      await waitFor(first, () => first.isFinished);
      expect(first.runError, isNull);
      expect(first.checkpointList, isNotEmpty);

      // Replay from the first checkpoint using a fresh workflow instance.
      final checkpoint = first.checkpointList.first;
      final recompiled = await compileWorkflowSpec(
        spec,
        buildAgent: buildScriptedAgent,
      );
      final replay = WorkflowRunController(
        workflow: recompiled.workflow,
        encodeResponse: recompiled.encodeResponse,
        checkpoints: manager,
      );
      await replay.startFromCheckpoint(checkpoint.info);
      await waitFor(replay, () => replay.isFinished);

      expect(replay.runError, isNull);
      expect(
        replay.finalOutput.map((m) => m.text),
        contains('Editor-reply'),
      );
      first.dispose();
      replay.dispose();
    });

    test('compiled diamond spec fans out and merges', () async {
      final spec = WorkflowSpec(
        id: 'w6',
        name: 'Diamond',
        nodes: [
          WorkflowNodeSpec(
            id: 'root',
            kind: WorkflowNodeKind.agent,
            label: 'Router',
          ),
          WorkflowNodeSpec(
            id: 'left',
            kind: WorkflowNodeKind.agent,
            label: 'Left',
          ),
          WorkflowNodeSpec(
            id: 'right',
            kind: WorkflowNodeKind.agent,
            label: 'Right',
          ),
          WorkflowNodeSpec(
            id: 'join',
            kind: WorkflowNodeKind.merge,
            label: 'Join',
          ),
          WorkflowNodeSpec(
            id: 'out',
            kind: WorkflowNodeKind.output,
            label: 'Out',
          ),
        ],
        edges: const [
          WorkflowEdgeSpec('root', 'left'),
          WorkflowEdgeSpec('root', 'right'),
          WorkflowEdgeSpec('left', 'join'),
          WorkflowEdgeSpec('right', 'join'),
          WorkflowEdgeSpec('join', 'out'),
        ],
      );
      expect(spec.validate(), isEmpty);

      final compiled = await compileWorkflowSpec(
        spec,
        buildAgent: buildScriptedAgent,
      );
      final controller = WorkflowRunController(workflow: compiled.workflow);

      await controller.start('go');
      await waitFor(controller, () => controller.isFinished);

      expect(controller.runError, isNull);
      final texts = controller.finalOutput.map((m) => m.text).toList();
      expect(texts.join(), contains('Left-reply'));
      expect(texts.join(), contains('Right-reply'));
      controller.dispose();
    });
  });
}

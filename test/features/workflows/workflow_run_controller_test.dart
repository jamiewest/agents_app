// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:agents_app/features/workflows/demo_workflows.dart';
import 'package:agents_app/features/workflows/role_agent.dart';
import 'package:agents_app/features/workflows/workflow_run_controller.dart';
import 'package:extensions/ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_agent.dart';

/// Waits until [predicate] holds, driven by the controller's notifications.
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

void main() {
  group('WorkflowRunController', () {
    test('sequential demo runs to completion with stage text', () async {
      final workflow = DemoWorkflows.sequential([
        ScriptedAgent(
          name: 'Drafter',
          onRun: (messages, options) => assistantResponse('draft'),
        ),
        ScriptedAgent(
          name: 'Editor',
          onRun: (messages, options) => assistantResponse('final'),
        ),
      ], name: 'Test pipeline');
      final controller = WorkflowRunController(workflow: workflow);

      expect(controller.layers, [
        ['Drafter'],
        ['Editor'],
        ['OutputMessages'],
      ]);
      expect(controller.edges, hasLength(2));

      await controller.start('hello');
      await waitFor(controller, () => controller.isFinished);

      expect(
        controller.nodes['Drafter']!.status,
        WorkflowNodeStatus.done,
      );
      expect(controller.nodes['Editor']!.status, WorkflowNodeStatus.done);
      expect(controller.nodes['Drafter']!.text.toString(), 'draft');
      expect(controller.nodes['Editor']!.text.toString(), 'final');
      expect(controller.runError, isNull);
      expect(
        controller.finalOutput.map((m) => m.text),
        containsAll(['hello', 'draft', 'final']),
      );
      expect(controller.superSteps, greaterThanOrEqualTo(3));
      controller.dispose();
    });

    test('streaming updates fill text and reasoning buffers', () async {
      final workflow = DemoWorkflows.sequential([
        ScriptedAgent(
          name: 'Thinker',
          onStream: (messages, options) => [
            AgentResponseUpdate(
              role: ChatRole.assistant,
              contents: [TextReasoningContent('pondering…')],
            ),
            AgentResponseUpdate(role: ChatRole.assistant, content: 'ans'),
            AgentResponseUpdate(role: ChatRole.assistant, content: 'wer'),
          ],
        ),
      ], name: 'Thinking pipeline');
      final controller = WorkflowRunController(workflow: workflow);

      await controller.start('question');
      await waitFor(controller, () => controller.isFinished);

      final node = controller.nodes['Thinker']!;
      expect(node.reasoning.toString(), 'pondering…');
      expect(node.text.toString(), 'answer');
      controller.dispose();
    });

    test('concurrent demo fans out and merges both answers', () async {
      final workflow = DemoWorkflows.concurrent([
        ScriptedAgent(
          name: 'Optimist',
          onRun: (messages, options) => assistantResponse('yes', author: 'Optimist'),
        ),
        ScriptedAgent(
          name: 'Skeptic',
          onRun: (messages, options) => assistantResponse('no', author: 'Skeptic'),
        ),
      ], name: 'Test debate');
      final controller = WorkflowRunController(workflow: workflow);

      expect(controller.layers.first, ['Start']);
      expect(controller.layers[1], ['Optimist', 'Skeptic']);

      await controller.start('question');
      await waitFor(controller, () => controller.isFinished);

      expect(
        controller.finalOutput.map((m) => m.text),
        containsAll(['yes', 'no']),
      );
      controller.dispose();
    });

    test('reviewed demo pauses for feedback and resumes on respond', () async {
      late List<ChatMessage> editorSaw;
      final workflow = DemoWorkflows.reviewed([
        ScriptedAgent(
          name: 'Drafter',
          onRun: (messages, options) => assistantResponse('the draft'),
        ),
        ScriptedAgent(
          name: 'Editor',
          onRun: (messages, options) {
            editorSaw = messages;
            return assistantResponse('the final');
          },
        ),
      ], name: 'Test review');
      final controller = WorkflowRunController(
        workflow: workflow,
        encodeResponse: DemoWorkflows.encodeResponse,
      );

      expect(controller.layers, [
        ['Drafter'],
        ['Request review'],
        ['Editor'],
        ['OutputMessages'],
      ]);

      await controller.start('hello');
      await waitFor(
        controller,
        () => controller.status == RunStatus.pendingRequests,
      );

      final request = controller.pendingRequests.single;
      expect(request.port.id, DemoWorkflows.reviewGateId);
      expect('${request.request}', contains('the draft'));
      expect(controller.isFinished, isFalse);

      await controller.respond(request, 'make it rhyme');
      await waitFor(controller, () => controller.isFinished);

      expect(controller.pendingRequests, isEmpty);
      expect(
        editorSaw.map((m) => m.text),
        contains('Reviewer feedback: make it rhyme'),
      );
      expect(controller.finalOutput.map((m) => m.text), contains('the final'));
      controller.dispose();
    });

    test('RoleAgent renames the agent and prepends role instructions', () async {
      late List<ChatMessage> seen;
      final inner = ScriptedAgent(
        name: 'inner',
        onRun: (messages, options) {
          seen = messages;
          return assistantResponse('ok');
        },
      );
      final role = RoleAgent(
        inner,
        role: 'Critic',
        roleInstructions: 'Be critical.',
      );

      expect(role.name, 'Critic');
      final session = await role.createSession();
      await role.run(
        session,
        null,
        messages: [ChatMessage.fromText(ChatRole.user, 'hi')],
      );

      expect(seen.first.role, ChatRole.system);
      expect(seen.first.text, 'Be critical.');
      expect(seen.last.text, 'hi');
    });
  });
}

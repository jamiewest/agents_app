// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';

import 'review_gate_executor.dart';

/// Builders for the demo workflows shown on the Workflows screen.
///
/// These mirror the shapes of the framework's [SequentialWorkflowBuilder]
/// and [ConcurrentWorkflowBuilder], but host each agent with
/// `emitAgentUpdateEvents` enabled so the run inspector can stream every
/// stage's tokens live — the stock builders don't expose that option.
abstract final class DemoWorkflows {
  /// Host options that surface streamed updates and responses as events.
  static const AIAgentHostOptions _hostOptions = AIAgentHostOptions(
    emitAgentUpdateEvents: true,
    emitAgentResponseEvents: true,
  );

  /// A pipeline: each agent's output feeds the next; the terminal executor
  /// yields the accumulated conversation.
  static Workflow sequential(List<AIAgent> agents, {required String name}) {
    final executors = [
      for (final agent in agents)
        AIAgentHostExecutor(agent, options: _hostOptions),
    ];
    final builder = WorkflowBuilder(ExecutorInstanceBinding(executors.first));
    var previousId = executors.first.id;
    for (final executor in executors.skip(1)) {
      builder.bindExecutor(executor).addEdge(previousId, executor.id);
      previousId = executor.id;
    }
    final end = OutputMessagesExecutor();
    builder
      ..bindExecutor(end)
      ..addEdge(previousId, end.id)
      ..withOutputFrom([end.id])
      // Output events pass an authorisation filter; without this, the
      // agents' streamed updates never leave the run.
      ..withIntermediateOutputFrom([for (final e in executors) e.id])
      ..withName(name);
    return builder.build();
  }

  /// Executor (and port) id of the review gate in [reviewed] workflows.
  static const String reviewGateId = 'Request review';

  /// Wraps plain reply text into the value a pending request expects:
  /// review-gate replies travel as [ReviewReply], everything else as text.
  static Object? encodeResponse(
    ExternalRequest<dynamic, dynamic> request,
    String text,
  ) => request.port.id == reviewGateId ? ReviewReply(text) : text;

  /// A pipeline with a human gate: the first agent drafts, the run pauses
  /// for reviewer feedback, and the second agent applies it.
  static Workflow reviewed(List<AIAgent> agents, {required String name}) {
    final executors = [
      for (final agent in agents)
        AIAgentHostExecutor(agent, options: _hostOptions),
    ];
    final gate = ReviewGateExecutor(reviewGateId);
    final end = OutputMessagesExecutor();
    final builder = WorkflowBuilder(ExecutorInstanceBinding(executors.first))
      ..bindExecutor(gate)
      ..bindExecutor(executors.last)
      ..bindExecutor(end)
      ..addEdge(executors.first.id, gate.id)
      ..addEdge(gate.id, executors.last.id)
      ..addEdge(executors.last.id, end.id)
      ..withOutputFrom([end.id])
      ..withIntermediateOutputFrom([for (final e in executors) e.id])
      ..withName(name);
    return builder.build();
  }

  /// A fan-out/fan-in: every agent answers the same input in parallel and
  /// the end executor merges their answers.
  static Workflow concurrent(List<AIAgent> agents, {required String name}) {
    final start = FunctionExecutor<List<ChatMessage>, List<ChatMessage>>(
      'Start',
      (input, context, cancellationToken) => input,
    );
    final builder = WorkflowBuilder(ExecutorInstanceBinding(start));

    final executors = <AIAgentHostExecutor>[];
    final batchers = <AggregateTurnMessagesExecutor>[];
    for (final agent in agents) {
      final executor = AIAgentHostExecutor(
        agent,
        options: _hostOptions.copyWith(forwardIncomingMessages: false),
      );
      executors.add(executor);
      batchers.add(AggregateTurnMessagesExecutor('Batch ${executor.id}'));
      builder.bindExecutor(executor);
    }
    for (final batcher in batchers) {
      builder.bindExecutor(batcher);
    }

    builder.addFanOutEdge(start.id, [for (final e in executors) e.id]);
    for (var i = 0; i < executors.length; i++) {
      builder.addEdge(executors[i].id, batchers[i].id);
    }

    final end = ConcurrentEndExecutor(
      executors.length,
      (lists) => [for (final list in lists) ...list],
    );
    builder
      ..bindExecutor(end)
      ..addFanInEdge([for (final batcher in batchers) batcher.id], end.id)
      ..withOutputFrom([end.id])
      ..withIntermediateOutputFrom([for (final e in executors) e.id])
      ..withName(name);
    return builder.build();
  }
}

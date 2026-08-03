// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

import 'review_gate_executor.dart';

/// The kinds of node the workflow editor can place.
enum WorkflowNodeKind {
  /// An agent stage: a configured agent cast into a named role.
  agent('Agent'),

  /// A human review gate: pauses the run for reviewer feedback.
  review('Review'),

  /// A merge point: joins parallel branches into one message list.
  merge('Merge'),

  /// A terminal output: whatever reaches it is the workflow's result.
  output('Output');

  const WorkflowNodeKind(this.label);

  /// Palette/display label.
  final String label;
}

/// One node in an editable workflow graph.
class WorkflowNodeSpec {
  /// Creates a node spec.
  WorkflowNodeSpec({
    required this.id,
    required this.kind,
    required this.label,
    this.instructions = '',
    this.agentId,
    this.x = 0,
    this.y = 0,
  });

  /// Reads a node from its stored [record].
  factory WorkflowNodeSpec.fromRecord(Map<String, Object?> record) =>
      WorkflowNodeSpec(
        id: record['id']! as String,
        kind:
            WorkflowNodeKind.values.asNameMap()[record['kind']] ??
            WorkflowNodeKind.agent,
        label: record['label'] as String? ?? '',
        instructions: record['instructions'] as String? ?? '',
        agentId: record['agentId'] as String?,
        x: (record['x'] as num?)?.toDouble() ?? 0,
        y: (record['y'] as num?)?.toDouble() ?? 0,
      );

  /// Stable node identity; edges reference this, never [label].
  final String id;

  /// What the node compiles to.
  final WorkflowNodeKind kind;

  /// Display name and executor id; unique within a workflow.
  String label;

  /// Role instructions, for [WorkflowNodeKind.agent] nodes.
  String instructions;

  /// The saved agent powering this stage; null means the runner's default.
  String? agentId;

  /// Canvas position.
  double x, y;

  /// This node as a stored record.
  Map<String, Object?> toRecord() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    'instructions': instructions,
    'agentId': agentId,
    'x': x,
    'y': y,
  };
}

/// A directed connection between two nodes, by node id.
class WorkflowEdgeSpec {
  /// Creates an edge from [from] to [to].
  const WorkflowEdgeSpec(this.from, this.to);

  /// Source node id.
  final String from;

  /// Target node id.
  final String to;
}

/// An editable, persistable workflow definition.
class WorkflowSpec {
  /// Creates a workflow spec.
  WorkflowSpec({
    required this.id,
    required this.name,
    List<WorkflowNodeSpec>? nodes,
    List<WorkflowEdgeSpec>? edges,
  }) : nodes = nodes ?? [],
       edges = edges ?? [];

  /// Reads a spec from its stored [record].
  factory WorkflowSpec.fromRecord(String id, Map<String, Object?> record) =>
      WorkflowSpec(
        id: id,
        name: record['name'] as String? ?? 'Untitled workflow',
        nodes: [
          for (final node in (record['nodes'] as List?) ?? const [])
            WorkflowNodeSpec.fromRecord((node as Map).cast<String, Object?>()),
        ],
        edges: [
          for (final edge in (record['edges'] as List?) ?? const [])
            WorkflowEdgeSpec(
              (edge as Map)['from']! as String,
              edge['to']! as String,
            ),
        ],
      );

  /// A prefilled spec for [template], or a blank canvas for
  /// [WorkflowTemplate.blank].
  factory WorkflowSpec.fromTemplate(String id, WorkflowTemplate template) {
    WorkflowNodeSpec agent(
      String nodeId,
      String label,
      String instructions,
      double x,
      double y,
    ) => WorkflowNodeSpec(
      id: nodeId,
      kind: WorkflowNodeKind.agent,
      label: label,
      instructions: instructions,
      x: x,
      y: y,
    );
    WorkflowNodeSpec node(
      String nodeId,
      WorkflowNodeKind kind,
      String label,
      double x,
      double y,
    ) => WorkflowNodeSpec(id: nodeId, kind: kind, label: label, x: x, y: y);

    switch (template) {
      case WorkflowTemplate.blank:
        return WorkflowSpec.starter(id);
      case WorkflowTemplate.pipeline:
        return WorkflowSpec(
          id: id,
          name: 'Draft, then edit',
          nodes: [
            agent(
              'n1',
              'Drafter',
              'Draft a direct, complete answer to the request. '
                  'Keep it brief.',
              60,
              120,
            ),
            agent(
              'n2',
              'Editor',
              'Review the draft above and reply with an improved final '
                  'answer only. Keep it brief.',
              320,
              120,
            ),
            node('n3', WorkflowNodeKind.output, 'Output', 580, 120),
          ],
          edges: const [
            WorkflowEdgeSpec('n1', 'n2'),
            WorkflowEdgeSpec('n2', 'n3'),
          ],
        );
      case WorkflowTemplate.debate:
        return WorkflowSpec(
          id: id,
          name: 'Debate in parallel',
          nodes: [
            agent(
              'n1',
              'Router',
              'Restate the request clearly in one sentence.',
              60,
              190,
            ),
            agent(
              'n2',
              'Optimist',
              'Answer emphasizing the best ideas and opportunities. '
                  'Keep it brief.',
              320,
              90,
            ),
            agent(
              'n3',
              'Skeptic',
              'Answer emphasizing risks, pitfalls, and counterpoints. '
                  'Keep it brief.',
              320,
              290,
            ),
            node('n4', WorkflowNodeKind.merge, 'Combine', 580, 190),
            node('n5', WorkflowNodeKind.output, 'Output', 840, 190),
          ],
          edges: const [
            WorkflowEdgeSpec('n1', 'n2'),
            WorkflowEdgeSpec('n1', 'n3'),
            WorkflowEdgeSpec('n2', 'n4'),
            WorkflowEdgeSpec('n3', 'n4'),
            WorkflowEdgeSpec('n4', 'n5'),
          ],
        );
      case WorkflowTemplate.reviewed:
        return WorkflowSpec(
          id: id,
          name: 'Draft, review, edit',
          nodes: [
            agent(
              'n1',
              'Drafter',
              'Draft a direct, complete answer to the request. '
                  'Keep it brief.',
              60,
              120,
            ),
            node('n2', WorkflowNodeKind.review, 'Check with me', 320, 120),
            agent(
              'n3',
              'Editor',
              'Revise the draft according to the reviewer feedback and '
                  'reply with the final answer only. Keep it brief.',
              580,
              120,
            ),
            node('n4', WorkflowNodeKind.output, 'Output', 840, 120),
          ],
          edges: const [
            WorkflowEdgeSpec('n1', 'n2'),
            WorkflowEdgeSpec('n2', 'n3'),
            WorkflowEdgeSpec('n3', 'n4'),
          ],
        );
    }
  }

  /// A minimal runnable starting point: one agent wired to an output.
  factory WorkflowSpec.starter(String id) => WorkflowSpec(
    id: id,
    name: 'Untitled workflow',
    nodes: [
      WorkflowNodeSpec(
        id: 'n1',
        kind: WorkflowNodeKind.agent,
        label: 'Assistant',
        instructions: 'Answer the request directly. Keep it brief.',
        x: 60,
        y: 120,
      ),
      WorkflowNodeSpec(
        id: 'n2',
        kind: WorkflowNodeKind.output,
        label: 'Output',
        x: 320,
        y: 120,
      ),
    ],
    edges: [const WorkflowEdgeSpec('n1', 'n2')],
  );

  /// Stable identity in the store.
  final String id;

  /// Display name.
  String name;

  /// The graph's nodes.
  final List<WorkflowNodeSpec> nodes;

  /// The graph's edges.
  final List<WorkflowEdgeSpec> edges;

  /// The node with [nodeId], or null.
  WorkflowNodeSpec? node(String nodeId) =>
      nodes.where((n) => n.id == nodeId).firstOrNull;

  /// A fresh node id not used by any current node.
  String nextNodeId() {
    var index = nodes.length + 1;
    while (nodes.any((n) => n.id == 'n$index')) {
      index++;
    }
    return 'n$index';
  }

  /// This spec as a stored record.
  Map<String, Object?> toRecord() => {
    'name': name,
    'nodes': [for (final node in nodes) node.toRecord()],
    'edges': [
      for (final edge in edges) {'from': edge.from, 'to': edge.to},
    ],
  };

  /// Checks the graph and returns the problems found, empty when runnable.
  List<String> validate() {
    final problems = <String>[];
    if (nodes.isEmpty) {
      return ['Add at least one node.'];
    }
    final labels = <String>{};
    for (final node in nodes) {
      if (node.label.trim().isEmpty) {
        problems.add('Every node needs a name.');
        break;
      }
    }
    for (final node in nodes) {
      if (!labels.add(node.label.trim())) {
        problems.add('Node names must be unique ("${node.label}" repeats).');
      }
    }
    for (final edge in edges) {
      if (node(edge.from) == null || node(edge.to) == null) {
        problems.add('An edge references a deleted node.');
      }
    }

    final incoming = <String, int>{};
    final outgoing = <String, int>{};
    for (final edge in edges) {
      incoming[edge.to] = (incoming[edge.to] ?? 0) + 1;
      outgoing[edge.from] = (outgoing[edge.from] ?? 0) + 1;
    }

    final entries = [
      for (final node in nodes)
        if ((incoming[node.id] ?? 0) == 0) node,
    ];
    if (entries.length != 1) {
      problems.add(
        'Exactly one node may have no incoming connection (the start); '
        'found ${entries.length}.',
      );
    } else if (entries.single.kind == WorkflowNodeKind.output) {
      problems.add('The start node cannot be an Output.');
    }

    final outputs = nodes.where((n) => n.kind == WorkflowNodeKind.output);
    if (outputs.isEmpty) {
      problems.add('Add an Output node; it collects the final result.');
    }
    for (final node in nodes) {
      if (node.kind == WorkflowNodeKind.output &&
          (outgoing[node.id] ?? 0) > 0) {
        problems.add('Output "${node.label}" cannot have outgoing edges.');
      }
      if ((incoming[node.id] ?? 0) > 1 && node.kind != WorkflowNodeKind.merge) {
        problems.add(
          'Only Merge nodes may have multiple incoming connections '
          '("${node.label}" has ${incoming[node.id]}).',
        );
      }
      if (node.kind != WorkflowNodeKind.output &&
          (outgoing[node.id] ?? 0) == 0) {
        problems.add('"${node.label}" leads nowhere; connect it or delete it.');
      }
    }

    if (_hasCycle()) {
      problems.add('The graph has a cycle; workflows must flow forward.');
    }
    return problems;
  }

  bool _hasCycle() {
    final adjacency = <String, List<String>>{};
    for (final edge in edges) {
      adjacency.putIfAbsent(edge.from, () => []).add(edge.to);
    }
    final visiting = <String>{};
    final done = <String>{};
    bool visit(String id) {
      if (done.contains(id)) return false;
      if (!visiting.add(id)) return true;
      for (final next in adjacency[id] ?? const <String>[]) {
        if (visit(next)) return true;
      }
      visiting.remove(id);
      done.add(id);
      return false;
    }

    return nodes.any((n) => visit(n.id));
  }
}

/// Starting points offered when creating a new workflow.
enum WorkflowTemplate {
  /// The minimal agent-to-output canvas.
  blank('Blank'),

  /// Drafter feeding an Editor.
  pipeline('Pipeline'),

  /// Two viewpoints answering in parallel, merged.
  debate('Debate'),

  /// A pipeline with a human review gate in the middle.
  reviewed('Reviewed');

  const WorkflowTemplate(this.label);

  /// Menu label.
  final String label;
}

/// A spec compiled into a runnable [Workflow].
class CompiledWorkflow {
  /// Creates a compiled workflow.
  const CompiledWorkflow({
    required this.workflow,
    required this.encodeResponse,
  });

  /// The runnable workflow.
  final Workflow workflow;

  /// Adapter from reply text to the value a pending request expects;
  /// review-gate replies travel as [ReviewReply].
  final Object? Function(ExternalRequest<dynamic, dynamic> request, String text)
  encodeResponse;
}

/// Compiles [spec] into a runnable workflow.
///
/// [buildAgent] resolves an agent node into the live [AIAgent] for its
/// stage (typically a `RoleAgent` over a configured agent, named after the
/// node's label). Throws [StateError] when the spec does not validate.
Future<CompiledWorkflow> compileWorkflowSpec(
  WorkflowSpec spec, {
  required Future<AIAgent> Function(WorkflowNodeSpec node) buildAgent,
}) async {
  final problems = spec.validate();
  if (problems.isNotEmpty) {
    throw StateError(problems.join(' '));
  }

  const hostOptions = AIAgentHostOptions(
    emitAgentUpdateEvents: true,
    emitAgentResponseEvents: true,
  );

  final incoming = <String, List<WorkflowEdgeSpec>>{};
  for (final edge in spec.edges) {
    incoming.putIfAbsent(edge.to, () => []).add(edge);
  }

  final executors = <String, Executor<dynamic, dynamic>>{};
  final reviewPortIds = <String>{};
  final agentLabels = <String>[];
  final outputLabels = <String>[];
  for (final node in spec.nodes) {
    final label = node.label.trim();
    switch (node.kind) {
      case WorkflowNodeKind.agent:
        executors[node.id] = AIAgentHostExecutor(
          await buildAgent(node),
          options: hostOptions,
          id: label,
        );
        agentLabels.add(label);
      case WorkflowNodeKind.review:
        executors[node.id] = ReviewGateExecutor(label);
        reviewPortIds.add(label);
      case WorkflowNodeKind.merge:
        executors[node.id] = _MergeExecutor(label);
      case WorkflowNodeKind.output:
        executors[node.id] =
            FunctionExecutor<List<ChatMessage>, List<ChatMessage>>(
              label,
              (input, context, cancellationToken) => input,
            );
        outputLabels.add(label);
    }
  }

  final entry = spec.nodes.singleWhere(
    (n) => (incoming[n.id] ?? const []).isEmpty,
  );
  final builder = WorkflowBuilder(
    ExecutorInstanceBinding(executors[entry.id]!),
  );
  for (final node in spec.nodes) {
    if (node.id != entry.id) builder.bindExecutor(executors[node.id]!);
  }

  String labelOf(String nodeId) => executors[nodeId]!.id;

  // Merge targets consume their edges as one fan-in; the rest group by
  // source into direct or fan-out edges.
  final fanInEdges = <WorkflowEdgeSpec>{};
  for (final node in spec.nodes) {
    final sources = incoming[node.id] ?? const [];
    if (node.kind == WorkflowNodeKind.merge && sources.length > 1) {
      builder.addFanInEdge([
        for (final edge in sources) labelOf(edge.from),
      ], labelOf(node.id));
      fanInEdges.addAll(sources);
    }
  }
  final bySource = <String, List<WorkflowEdgeSpec>>{};
  for (final edge in spec.edges) {
    if (fanInEdges.contains(edge)) continue;
    bySource.putIfAbsent(edge.from, () => []).add(edge);
  }
  for (final entry in bySource.entries) {
    final targets = [for (final edge in entry.value) labelOf(edge.to)];
    if (targets.length > 1) {
      builder.addFanOutEdge(labelOf(entry.key), targets);
    } else {
      builder.addEdge(labelOf(entry.key), targets.single);
    }
  }

  builder
    ..withOutputFrom(outputLabels)
    ..withIntermediateOutputFrom(agentLabels)
    ..withName(spec.name);

  return CompiledWorkflow(
    workflow: builder.build(),
    encodeResponse: (request, text) =>
        reviewPortIds.contains(request.port.id) ? ReviewReply(text) : text,
  );
}

/// Joins the message lists arriving over a fan-in edge into one list.
class _MergeExecutor extends Executor<Object?, List<ChatMessage>> {
  _MergeExecutor(super.id);

  @override
  void configureProtocol(ProtocolBuilder builder) {
    builder
      ..acceptsMessage<List<Object?>>()
      ..acceptsMessage<List<ChatMessage>>()
      ..sendsMessage<List<ChatMessage>>();
  }

  @override
  Future<List<ChatMessage>> handle(
    Object? message,
    WorkflowContext context, {
    CancellationToken? cancellationToken,
  }) async {
    if (message is Iterable<ChatMessage>) {
      return List<ChatMessage>.of(message);
    }
    if (message is Iterable<Object?>) {
      return [for (final item in message) ...ChatProtocol.toChatMessages(item)];
    }
    return ChatProtocol.toChatMessages(message);
  }
}

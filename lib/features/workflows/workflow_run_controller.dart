// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:flutter/foundation.dart';

/// Lifecycle of one executor node as seen by the run inspector.
enum WorkflowNodeStatus {
  /// Not yet invoked this run.
  idle,

  /// Invoked and currently working.
  running,

  /// Completed at least once.
  done,

  /// Threw; see [WorkflowNodeState.error].
  failed,
}

/// Live inspector state for one executor in the workflow graph.
class WorkflowNodeState {
  /// Creates state for the executor with [id].
  WorkflowNodeState(this.id);

  /// The executor id (also the graph node label).
  final String id;

  /// Where the node is in its lifecycle.
  WorkflowNodeStatus status = WorkflowNodeStatus.idle;

  /// Streamed agent text accumulated so far, empty for non-agent nodes.
  final StringBuffer text = StringBuffer();

  /// Streamed reasoning ("thinking") text, for models that emit it.
  final StringBuffer reasoning = StringBuffer();

  /// The failure, when [status] is [WorkflowNodeStatus.failed].
  String? error;

  /// When the node was last invoked.
  DateTime? startedAt;

  /// When the node last completed or failed.
  DateTime? finishedAt;

  /// How long the node's last invocation took, when known.
  Duration? get elapsed => switch ((startedAt, finishedAt)) {
    (final start?, final end?) => end.difference(start),
    _ => null,
  };
}

/// One line in the run's event log.
class WorkflowRunLogEntry {
  /// Creates a log entry stamped with the current time.
  WorkflowRunLogEntry(this.label, {this.detail}) : time = DateTime.now();

  /// When the event arrived.
  final DateTime time;

  /// Short human-readable description.
  final String label;

  /// Optional longer payload text.
  final String? detail;
}

/// Drives a single workflow run and exposes its live state to the
/// inspector UI.
///
/// One controller runs one [Workflow] instance exactly once ([start]);
/// build a fresh workflow and controller for each run — the engine ties
/// workflow ownership to its run. Events arrive through an
/// [AsyncRunHandle], so the graph lights up while the run is still
/// executing, and [respond] answers human-in-the-loop requests.
class WorkflowRunController extends ChangeNotifier {
  /// Creates a controller for one run of [workflow].
  ///
  /// [encodeResponse] converts the user's plain-text answer to a pending
  /// request into the value its port expects; when omitted (or when it
  /// returns null) the raw text is sent. Passing [checkpoints] records a
  /// checkpoint per superstep, surfaced via [checkpointList].
  WorkflowRunController({
    required this.workflow,
    this.encodeResponse,
    this.checkpoints,
  }) {
    for (final binding in workflow.reflectExecutors()) {
      nodes[binding.id] = WorkflowNodeState(binding.id);
    }
    edges = [
      for (final edge in workflow.reflectEdges())
        for (final source in edge.sourceExecutorIds)
          for (final target in edge.targetExecutorIds) (source, target),
    ];
    layers = _computeLayers();
  }

  /// The workflow this controller runs.
  final Workflow workflow;

  /// Optional adapter from reply text to a port's response value.
  final Object? Function(
    ExternalRequest<dynamic, dynamic> request,
    String text,
  )?
  encodeResponse;

  /// Optional checkpoint manager; enables [checkpointList] and resume.
  final InMemoryCheckpointManager? checkpoints;

  /// Checkpoints recorded so far, oldest first.
  List<Checkpoint> checkpointList = const [];

  /// Node state keyed by executor id.
  final Map<String, WorkflowNodeState> nodes = {};

  /// Every (source, target) pair in the graph, fan edges expanded.
  late final List<(String, String)> edges;

  /// Executor ids grouped by graph depth, for left-to-right layout.
  late final List<List<String>> layers;

  /// Chronological run events, newest last.
  final List<WorkflowRunLogEntry> log = [];

  /// Requests waiting on a human answer.
  final List<ExternalRequest<dynamic, dynamic>> pendingRequests = [];

  /// The terminal workflow output, empty until the run yields it.
  List<ChatMessage> finalOutput = const [];

  /// The run status as derived from observed events.
  RunStatus status = RunStatus.notStarted;

  /// How many supersteps have started.
  int superSteps = 0;

  /// A workflow-level error, when the run failed.
  String? runError;

  AsyncRunHandle<List<ChatMessage>>? _handle;
  StreamingRun? _resumedRun;
  StreamSubscription<WorkflowEvent>? _subscription;
  bool _disposed = false;

  /// Whether the run has finished (successfully or not).
  bool get isFinished => status == RunStatus.ended;

  /// Starts the run with [prompt] as the user message.
  ///
  /// May be called once; subsequent calls throw.
  Future<void> start(String prompt) async {
    if (_handle != null || _resumedRun != null) {
      throw StateError('WorkflowRunController.start may only be called once.');
    }
    final handle = AsyncRunHandle.open<List<ChatMessage>>(
      workflow,
      input: [ChatMessage.fromText(ChatRole.user, prompt)],
      checkpointManager: checkpoints,
    );
    _handle = handle;
    status = RunStatus.running;
    _log('Run started');
    _listen(handle.events);
    notifyListeners();
  }

  /// Resumes the run from [checkpoint] instead of starting fresh.
  ///
  /// Requires [checkpoints] (holding the checkpoint's data) and a fresh
  /// [workflow] instance. May be called once, instead of [start].
  Future<void> startFromCheckpoint(CheckpointInfo checkpoint) async {
    final manager = checkpoints;
    if (manager == null) {
      throw StateError('startFromCheckpoint needs a checkpoint manager.');
    }
    if (_handle != null || _resumedRun != null) {
      throw StateError('WorkflowRunController.start may only be called once.');
    }
    status = RunStatus.running;
    _log('Resuming from checkpoint');
    final run = await inProcessExecution.resumeStreamAsync(
      workflow,
      checkpoint,
      manager,
    );
    _resumedRun = run;
    _listen(run.watchStreamAsync());
    notifyListeners();
  }

  void _listen(Stream<WorkflowEvent> events) {
    _subscription = events.listen(
      _onEvent,
      onError: (Object error) {
        runError = '$error';
        status = RunStatus.ended;
        _log('Run failed', detail: '$error');
        notifyListeners();
      },
      onDone: () {
        if (status != RunStatus.pendingRequests) status = RunStatus.ended;
        _log('Run ended');
        notifyListeners();
      },
    );
  }

  /// Answers [request] with [text] and resumes the run.
  Future<void> respond(
    ExternalRequest<dynamic, dynamic> request,
    String text,
  ) async {
    if (_handle == null && _resumedRun == null) return;
    pendingRequests.remove(request);
    status = RunStatus.running;
    _log('Answered request "${request.port.id}"', detail: text);
    notifyListeners();
    final value = encodeResponse?.call(request, text) ?? text;
    final response = request.createResponse(value);
    if (_handle case final handle?) {
      await handle.sendResponseAsync(response);
    } else if (_resumedRun case final run?) {
      await run.sendResponseAsync(response);
    }
  }

  Future<void> _refreshCheckpoints() async {
    final store = checkpoints?.jsonStore;
    if (store == null) return;
    final list = await store.listCheckpointsAsync();
    if (_disposed) return;
    checkpointList = list;
    notifyListeners();
  }

  /// The workflow graph as a Mermaid flowchart definition.
  String toMermaid() => WorkflowVisualizer.toMermaid(workflow);

  void _onEvent(WorkflowEvent event) {
    switch (event) {
      case WorkflowStartedEvent():
        _log('Workflow started');
      case SuperStepStartedEvent():
        superSteps++;
        _log('Superstep $superSteps started');
      case SuperStepCompletedEvent():
        _log('Superstep $superSteps completed');
        unawaited(_refreshCheckpoints());
      case ExecutorInvokedEvent(:final executorId):
        _node(executorId)
          ..status = WorkflowNodeStatus.running
          ..startedAt = DateTime.now();
        _log('$executorId invoked');
      case ExecutorCompletedEvent(:final executorId):
        _node(executorId)
          ..status = WorkflowNodeStatus.done
          ..finishedAt = DateTime.now();
        _log('$executorId completed');
      case ExecutorFailedEvent(:final executorId, :final error):
        _node(executorId)
          ..status = WorkflowNodeStatus.failed
          ..error = '$error'
          ..finishedAt = DateTime.now();
        _log('$executorId failed', detail: '$error');
      case AgentResponseUpdateEvent(:final executorId, :final update):
        final node = _node(executorId);
        for (final content in update.contents) {
          switch (content) {
            case TextContent(:final text):
              node.text.write(text);
            case TextReasoningContent(:final text):
              node.reasoning.write(text);
          }
        }
      case AgentResponseEvent(:final executorId, :final response):
        // The aggregated response is authoritative: token-by-token buffers
        // can carry split multi-byte glyphs, so replace rather than append.
        final node = _node(executorId);
        node.text
          ..clear()
          ..write(response.text);
        final reasoning = [
          for (final message in response.messages)
            for (final content in message.contents)
              if (content is TextReasoningContent) content.text,
        ].join();
        if (reasoning.isNotEmpty) {
          node.reasoning
            ..clear()
            ..write(reasoning);
        }
      case RequestInfoEvent(:final request):
        pendingRequests.add(request);
        status = RunStatus.pendingRequests;
        _log(
          'Waiting on request "${request.port.id}"',
          detail: '${request.request}',
        );
      case RequestHaltEvent():
        _log('Halt requested');
      case WorkflowErrorEvent():
        runError = '${event.data}';
        _log('Workflow error', detail: '${event.data}');
      case WorkflowWarningEvent():
        _log('Workflow warning', detail: '${event.data}');
      case WorkflowOutputEvent(data: final WorkflowEvent inner):
        // The runner wraps events yielded by executors (agent updates and
        // responses) in a WorkflowOutputEvent envelope; unwrap and re-route.
        _onEvent(inner);
      case WorkflowOutputEvent(:final executorId) when event.isIntermediate:
        // Stages hosted without streaming still surface their messages as
        // intermediate outputs; keep only what the stage itself said.
        final node = _node(executorId);
        if (event.data case final List<ChatMessage> messages
            when node.text.isEmpty) {
          node.text.write(
            messages
                .where((m) => m.role == ChatRole.assistant)
                .map((m) => m.text)
                .join('\n'),
          );
        }
      case WorkflowOutputEvent(:final executorId):
        if (event.data case final List<ChatMessage> messages) {
          finalOutput = messages;
        }
        _log('Output from $executorId');
      default:
        break;
    }
    notifyListeners();
  }

  WorkflowNodeState _node(String executorId) =>
      nodes.putIfAbsent(executorId, () => WorkflowNodeState(executorId));

  void _log(String label, {String? detail}) =>
      log.add(WorkflowRunLogEntry(label, detail: detail));

  /// Groups executors by breadth-first depth from the start executor.
  ///
  /// Executors unreachable from the start (none in the shipped builders,
  /// but possible in hand-built graphs) land in a trailing layer so the
  /// view never drops a node.
  List<List<String>> _computeLayers() {
    final adjacency = <String, Set<String>>{};
    for (final (source, target) in edges) {
      adjacency.putIfAbsent(source, () => <String>{}).add(target);
    }
    final depths = <String, int>{workflow.startExecutorId: 0};
    var frontier = <String>[workflow.startExecutorId];
    while (frontier.isNotEmpty) {
      final next = <String>[];
      for (final id in frontier) {
        for (final target in adjacency[id] ?? const <String>{}) {
          if (depths.containsKey(target)) continue;
          depths[target] = depths[id]! + 1;
          next.add(target);
        }
      }
      frontier = next;
    }
    final depthCount = depths.values.isEmpty
        ? 0
        : depths.values.reduce((a, b) => a > b ? a : b) + 1;
    final grouped = [
      for (var depth = 0; depth < depthCount; depth++)
        [
          for (final entry in depths.entries)
            if (entry.value == depth) entry.key,
        ],
    ];
    final unreachable = [
      for (final id in nodes.keys)
        if (!depths.containsKey(id)) id,
    ];
    if (unreachable.isNotEmpty) grouped.add(unreachable);
    return grouped;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

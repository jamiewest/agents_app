// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/workflows/workflow_checkpoint_store.dart';
import '../../features/workflows/workflow_launcher.dart';
import '../../features/workflows/workflow_run_controller.dart';
import '../../features/workflows/workflow_spec.dart';
import '../../features/workflows/workflow_spec_store.dart';
import '../app_theme.dart';
import '../widgets/page_body.dart';
import '../widgets/workflow_prompt_dialog.dart';
import '../widgets/workflow_run_inspector.dart';

const double _nodeWidth = 170;
const double _nodeHeight = 60;
const Size _canvasSize = Size(2400, 1600);

/// The drag-and-connect workflow editor.
///
/// Nodes from the palette are dragged around a canvas and wired together
/// by dragging from a node's output port onto another node. The graph is
/// persisted as a [WorkflowSpec] and compiled to a real engine [Workflow]
/// when run; the live inspector takes over the canvas area during a run.
class WorkflowEditorScreen extends StatefulWidget {
  /// Creates the editor for the workflow with [workflowId].
  const WorkflowEditorScreen({
    required this.services,
    required this.workflowId,
    this.template,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The spec id being edited; a missing id starts a fresh workflow.
  final String workflowId;

  /// Template name prefilling a fresh workflow; null means blank.
  final String? template;

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late final WorkflowSpecStore _store;
  late final WorkflowCheckpointStore _checkpoints;
  late final Future<List<SavedAgentConfig>> _agentsFuture;
  final TextEditingController _name = TextEditingController();
  final TransformationController _canvas = TransformationController();

  final GlobalKey _canvasKey = GlobalKey();
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'workflow-canvas');
  WorkflowSpec? _spec;

  /// The last run's persisted checkpoint trail, replayable while idle.
  List<Checkpoint> _savedCheckpoints = const [];
  String? _selectedNodeId;
  WorkflowEdgeSpec? _selectedEdge;
  (String fromNodeId, Offset point)? _pendingEdge;
  WorkflowRunController? _run;
  bool _starting = false;

  /// Converts a global pointer position into canvas coordinates.
  Offset _toCanvas(Offset global) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global) ?? global;
  }

  @override
  void initState() {
    super.initState();
    final records = widget.services.getRequiredService<RecordStore>();
    _store = WorkflowSpecStore(records);
    _checkpoints = WorkflowCheckpointStore(records);
    _agentsFuture = widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agents
        .listAgents();
    unawaited(_load());
  }

  Future<void> _load() async {
    final spec =
        await _store.get(widget.workflowId) ??
        WorkflowSpec.fromTemplate(
          widget.workflowId,
          WorkflowTemplate.values.asNameMap()[widget.template] ??
              WorkflowTemplate.blank,
        );
    if (!mounted) return;
    setState(() {
      _spec = spec;
      _name.text = spec.name;
    });
    await _refreshSavedCheckpoints();
  }

  /// Reloads the persisted checkpoint trail behind this workflow.
  Future<void> _refreshSavedCheckpoints() async {
    final saved = await _checkpoints.listCheckpointsAsync(
      sessionId: widget.workflowId,
    );
    if (!mounted) return;
    setState(() => _savedCheckpoints = saved);
  }

  @override
  void dispose() {
    _name.dispose();
    _canvas.dispose();
    _canvasFocus.dispose();
    _run?.dispose();
    super.dispose();
  }

  KeyEventResult _onCanvasKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_selectedEdge case final edge?) {
        _removeEdge(edge);
        return KeyEventResult.handled;
      }
      if (_selectedNodeId case final nodeId?) {
        _deleteNode(nodeId);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selectedNodeId = null;
        _selectedEdge = null;
        _pendingEdge = null;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The edge whose curve passes within 12 canvas pixels of [point].
  WorkflowEdgeSpec? _edgeAt(Offset point) {
    final spec = _spec;
    if (spec == null) return null;
    WorkflowEdgeSpec? closest;
    var best = 12.0;
    for (final edge in spec.edges) {
      final from = spec.node(edge.from);
      final to = spec.node(edge.to);
      if (from == null || to == null) continue;
      final start = Offset(from.x + _nodeWidth, from.y + _nodeHeight / 2);
      final end = Offset(to.x - 5, to.y + _nodeHeight / 2);
      final mid = (start.dx + end.dx) / 2;
      final c1 = Offset(mid, start.dy);
      final c2 = Offset(mid, end.dy);
      for (var i = 0; i <= 24; i++) {
        final t = i / 24;
        final u = 1 - t;
        final sample =
            start * (u * u * u) +
            c1 * (3 * u * u * t) +
            c2 * (3 * u * t * t) +
            end * (t * t * t);
        final distance = (sample - point).distance;
        if (distance < best) {
          best = distance;
          closest = edge;
        }
      }
    }
    return closest;
  }

  WorkflowNodeSpec? get _selectedNode => switch (_selectedNodeId) {
    null => null,
    final id => _spec?.node(id),
  };

  Future<void> _save() async {
    final spec = _spec;
    if (spec == null) return;
    spec.name = _name.text.trim().isEmpty ? 'Untitled workflow' : _name.text;
    await _store.save(spec);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Workflow saved.')));
    }
  }

  void _addNode(WorkflowNodeKind kind) {
    final spec = _spec;
    if (spec == null) return;
    final id = spec.nextNodeId();
    final labels = {for (final node in spec.nodes) node.label};
    var label = kind.label;
    var suffix = 2;
    while (labels.contains(label)) {
      label = '${kind.label} ${suffix++}';
    }
    setState(() {
      spec.nodes.add(
        WorkflowNodeSpec(
          id: id,
          kind: kind,
          label: label,
          instructions: kind == WorkflowNodeKind.agent
              ? 'Answer the request directly. Keep it brief.'
              : '',
          x: 80.0 + (spec.nodes.length % 5) * 60,
          y: 80.0 + (spec.nodes.length % 7) * 70,
        ),
      );
      _selectedNodeId = id;
    });
  }

  void _deleteNode(String nodeId) {
    final spec = _spec;
    if (spec == null) return;
    setState(() {
      spec.nodes.removeWhere((n) => n.id == nodeId);
      spec.edges.removeWhere((e) => e.from == nodeId || e.to == nodeId);
      if (_selectedNodeId == nodeId) _selectedNodeId = null;
    });
  }

  void _removeEdge(WorkflowEdgeSpec edge) => setState(() {
    _spec?.edges.remove(edge);
    if (_selectedEdge == edge) _selectedEdge = null;
  });

  void _finishPendingEdge() {
    final spec = _spec;
    final pending = _pendingEdge;
    if (spec == null || pending == null) return;
    final (fromId, point) = pending;
    setState(() => _pendingEdge = null);
    for (final node in spec.nodes) {
      final rect = Rect.fromLTWH(node.x, node.y, _nodeWidth, _nodeHeight);
      if (!rect.contains(point) || node.id == fromId) continue;
      final duplicate = spec.edges.any(
        (e) => e.from == fromId && e.to == node.id,
      );
      if (!duplicate) {
        final edge = WorkflowEdgeSpec(fromId, node.id);
        setState(() {
          spec.edges.add(edge);
          _selectedEdge = edge;
          _selectedNodeId = null;
        });
      }
      return;
    }
  }

  Future<void> _runWorkflow() async {
    final spec = _spec;
    if (spec == null || _starting) return;
    final problems = spec.validate();
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problems.first)));
      return;
    }
    final agents = await _agentsFuture;
    if (!mounted) return;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Workflows need a configured agent.'),
          action: SnackBarAction(
            label: 'Add agent',
            onPressed: () => context.go('/settings/agents/add'),
          ),
        ),
      );
      return;
    }
    final prompt = await showWorkflowPromptDialog(
      context,
      initialPrompt: spec.prompt,
    );
    if (prompt == null || prompt.trim().isEmpty || !mounted) return;

    setState(() => _starting = true);
    try {
      spec.prompt = prompt.trim();
      await _save();
      final controller = await createSpecRunController(widget.services, spec);
      final previous = _run;
      setState(() => _run = controller);
      previous?.dispose();
      await controller.start(prompt.trim());
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not start run: $error')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _closeRun() {
    final run = _run;
    setState(() => _run = null);
    run?.dispose();
    unawaited(_refreshSavedCheckpoints());
  }

  /// Rewinds to [checkpoint]: a fresh compile of the same spec resumed
  /// against the workflow's persisted checkpoint trail.
  ///
  /// The trail lives in the record store, so this also replays runs
  /// recorded before an app restart.
  Future<void> _replayCheckpoint(Checkpoint checkpoint) async {
    final spec = _spec;
    if (spec == null || _starting) return;
    setState(() => _starting = true);
    try {
      final controller = await createSpecRunController(
        widget.services,
        spec,
        checkpoints: _checkpoints.managerFor(spec.id),
      );
      final previous = _run;
      setState(() => _run = controller);
      previous?.dispose();
      await controller.startFromCheckpoint(checkpoint.info);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not replay: $error')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    return Scaffold(
      body: SafeArea(
        child: spec == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context),
                  const Divider(height: 1),
                  if (_run case final run?)
                    Expanded(
                      child: SingleChildScrollView(
                        child: PageBody(
                          child: ListenableBuilder(
                            listenable: run,
                            builder: (context, _) => WorkflowRunInspector(
                              run: run,
                              onDiscard: _closeRun,
                              onReplayCheckpoint: (checkpoint) =>
                                  unawaited(_replayCheckpoint(checkpoint)),
                            ),
                          ),
                        ),
                      ),
                    )
                  else ...[
                    _palette(context),
                    if (_savedCheckpoints.isNotEmpty)
                      _ReplayBar(
                        checkpoints: _savedCheckpoints,
                        busy: _starting,
                        onReplay: (checkpoint) =>
                            unawaited(_replayCheckpoint(checkpoint)),
                      ),
                    if (_selectedEdge case final edge?)
                      _EdgeBar(
                        label:
                            '${spec.node(edge.from)?.label ?? '?'} → '
                            '${spec.node(edge.to)?.label ?? '?'}',
                        onRemove: () => _removeEdge(edge),
                      ),
                    Expanded(child: _canvasView(context, spec)),
                    if (_selectedNode case final node?)
                      _PropertiesPanel(
                        node: node,
                        spec: spec,
                        agentsFuture: _agentsFuture,
                        onChanged: () => setState(() {}),
                        onDelete: () => _deleteNode(node.id),
                        onRemoveEdge: _removeEdge,
                      ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.sm,
      vertical: AppSpacing.sm,
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back to workflows',
          icon: const AppBackIcon(),
          onPressed: () => context.go('/workflows'),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: TextField(
            controller: _name,
            decoration: const InputDecoration(
              hintText: 'Workflow name',
              border: InputBorder.none,
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        if (_run == null) ...[
          OutlinedButton.icon(
            onPressed: _save,
            icon: const Icon(LucideIcons.save300, size: 18),
            label: const Text('Save'),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton.icon(
            onPressed: _starting ? null : _runWorkflow,
            icon: _starting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.play300, size: 18),
            label: const Text('Run'),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: _closeRun,
            icon: const Icon(LucideIcons.pencil300, size: 18),
            label: const Text('Back to canvas'),
          ),
        const SizedBox(width: AppSpacing.sm),
      ],
    ),
  );

  Widget _palette(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    ),
    child: Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Add', style: Theme.of(context).textTheme.labelLarge),
        for (final kind in WorkflowNodeKind.values)
          ActionChip(
            avatar: Icon(_kindIcon(kind), size: 16),
            label: Text(kind.label),
            onPressed: () => _addNode(kind),
          ),
        const SizedBox(width: AppSpacing.md),
        Text(
          'Drag from a node\'s ○ onto another node to connect.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _canvasView(BuildContext context, WorkflowSpec spec) => ClipRect(
    child: Container(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Focus(
        focusNode: _canvasFocus,
        onKeyEvent: _onCanvasKey,
        child: InteractiveViewer(
          transformationController: _canvas,
          constrained: false,
          minScale: 0.5,
          maxScale: 2,
          child: SizedBox(
            key: _canvasKey,
            width: _canvasSize.width,
            height: _canvasSize.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      _canvasFocus.requestFocus();
                      setState(() {
                        _selectedNodeId = null;
                        _selectedEdge = _edgeAt(details.localPosition);
                      });
                    },
                    child: CustomPaint(
                      painter: _EditorEdgePainter(
                        spec: spec,
                        pendingEdge: _pendingEdge,
                        selectedEdge: _selectedEdge,
                        color: Theme.of(context).colorScheme.outline,
                        pendingColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                for (final node in spec.nodes)
                  Positioned(
                    left: node.x,
                    top: node.y,
                    width: _nodeWidth,
                    height: _nodeHeight,
                    child: _EditorNodeCard(
                      node: node,
                      selected: node.id == _selectedNodeId,
                      onTap: () {
                        _canvasFocus.requestFocus();
                        setState(() {
                          _selectedNodeId = node.id;
                          _selectedEdge = null;
                        });
                      },
                      onMoved: (delta) => setState(() {
                        final scale = _canvas.value.getMaxScaleOnAxis();
                        node.x = (node.x + delta.dx / scale).clamp(
                          0,
                          _canvasSize.width - _nodeWidth,
                        );
                        node.y = (node.y + delta.dy / scale).clamp(
                          0,
                          _canvasSize.height - _nodeHeight,
                        );
                      }),
                      onPortDragStart: () => setState(() {
                        _pendingEdge = (
                          node.id,
                          Offset(node.x + _nodeWidth, node.y + _nodeHeight / 2),
                        );
                      }),
                      onPortDragUpdate: (globalPoint) => setState(() {
                        final pending = _pendingEdge;
                        if (pending != null) {
                          _pendingEdge = (pending.$1, _toCanvas(globalPoint));
                        }
                      }),
                      onPortDragEnd: _finishPendingEdge,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  static IconData _kindIcon(WorkflowNodeKind kind) => switch (kind) {
    WorkflowNodeKind.agent => LucideIcons.bot300,
    WorkflowNodeKind.review => LucideIcons.userCheck300,
    WorkflowNodeKind.merge => LucideIcons.gitMerge300,
    WorkflowNodeKind.output => LucideIcons.flag300,
  };
}

/// One draggable node card on the canvas.
class _EditorNodeCard extends StatelessWidget {
  const _EditorNodeCard({
    required this.node,
    required this.selected,
    required this.onTap,
    required this.onMoved,
    required this.onPortDragStart,
    required this.onPortDragUpdate,
    required this.onPortDragEnd,
  });

  final WorkflowNodeSpec node;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMoved;
  final VoidCallback onPortDragStart;
  final ValueChanged<Offset> onPortDragUpdate;
  final VoidCallback onPortDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (node.kind) {
      WorkflowNodeKind.agent => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      WorkflowNodeKind.review => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      WorkflowNodeKind.merge => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      WorkflowNodeKind.output => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
      ),
    };
    return GestureDetector(
      onTap: onTap,
      onPanStart: (_) => onTap(),
      onPanUpdate: (details) => onMoved(details.delta),
      child: Container(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Icon(
              _WorkflowEditorScreenState._kindIcon(node.kind),
              size: 16,
              color: foreground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // The output port: drag from here onto another node.
            GestureDetector(
              onPanStart: (details) {
                onPortDragStart();
                onPortDragUpdate(details.globalPosition);
              },
              onPanUpdate: (details) =>
                  onPortDragUpdate(details.globalPosition),
              onPanEnd: (_) => onPortDragEnd(),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surface,
                    border: Border.all(color: foreground, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edits the selected node: name, agent, instructions, and connections.
class _PropertiesPanel extends StatelessWidget {
  const _PropertiesPanel({
    required this.node,
    required this.spec,
    required this.agentsFuture,
    required this.onChanged,
    required this.onDelete,
    required this.onRemoveEdge,
  });

  final WorkflowNodeSpec node;
  final WorkflowSpec spec;
  final Future<List<SavedAgentConfig>> agentsFuture;
  final VoidCallback onChanged;
  final VoidCallback onDelete;
  final ValueChanged<WorkflowEdgeSpec> onRemoveEdge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touching = [
      for (final edge in spec.edges)
        if (edge.from == node.id || edge.to == node.id) edge,
    ];
    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('label-${node.id}'),
                    initialValue: node.label,
                    decoration: InputDecoration(
                      labelText: '${node.kind.label} name',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (value) {
                      node.label = value;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                IconButton(
                  tooltip: 'Delete node',
                  icon: const Icon(LucideIcons.trash2300, size: 18),
                  onPressed: onDelete,
                ),
              ],
            ),
            if (node.kind == WorkflowNodeKind.agent) ...[
              const SizedBox(height: AppSpacing.md),
              FutureBuilder<List<SavedAgentConfig>>(
                future: agentsFuture,
                builder: (context, snapshot) {
                  final agents = snapshot.data ?? const <SavedAgentConfig>[];
                  if (agents.isEmpty) return const SizedBox.shrink();
                  return DropdownButtonFormField<String>(
                    key: ValueKey('agent-${node.id}'),
                    initialValue: node.agentId ?? agents.first.id,
                    decoration: const InputDecoration(
                      labelText: 'Agent',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final agent in agents)
                        DropdownMenuItem(
                          value: agent.id,
                          child: Text(agent.name),
                        ),
                    ],
                    onChanged: (id) {
                      node.agentId = id;
                      onChanged();
                    },
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                key: ValueKey('instructions-${node.id}'),
                initialValue: node.instructions,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Role instructions',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) {
                  node.instructions = value;
                  onChanged();
                },
              ),
            ],
            if (touching.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text('Connections', style: theme.textTheme.labelLarge),
              for (final edge in touching)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${spec.node(edge.from)?.label ?? '?'} → '
                        '${spec.node(edge.to)?.label ?? '?'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove connection',
                      icon: const Icon(LucideIcons.x300, size: 16),
                      onPressed: () => onRemoveEdge(edge),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Paints the editor's edges plus the in-progress connection drag.
class _EditorEdgePainter extends CustomPainter {
  _EditorEdgePainter({
    required this.spec,
    required this.pendingEdge,
    required this.selectedEdge,
    required this.color,
    required this.pendingColor,
  });

  final WorkflowSpec spec;
  final (String, Offset)? pendingEdge;
  final WorkflowEdgeSpec? selectedEdge;
  final Color color;
  final Color pendingColor;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    final head = Paint()..color = color;

    final selectedLine = Paint()
      ..color = pendingColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final selectedHead = Paint()..color = pendingColor;

    for (final edge in spec.edges) {
      final from = spec.node(edge.from);
      final to = spec.node(edge.to);
      if (from == null || to == null) continue;
      final selected = identical(edge, selectedEdge);
      final start = Offset(from.x + _nodeWidth, from.y + _nodeHeight / 2);
      final end = Offset(to.x - 5, to.y + _nodeHeight / 2);
      final mid = (start.dx + end.dx) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(mid, start.dy, mid, end.dy, end.dx, end.dy),
        selected ? selectedLine : line,
      );
      canvas.drawPath(
        Path()
          ..moveTo(end.dx + 5, end.dy)
          ..lineTo(end.dx - 2, end.dy - 5)
          ..lineTo(end.dx - 2, end.dy + 5)
          ..close(),
        selected ? selectedHead : head,
      );
    }

    if (pendingEdge case (final fromId, final point)) {
      final from = spec.node(fromId);
      if (from != null) {
        canvas.drawLine(
          Offset(from.x + _nodeWidth, from.y + _nodeHeight / 2),
          point,
          Paint()
            ..color = pendingColor
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_EditorEdgePainter oldDelegate) => true;
}

/// The slim bar offering replays of the last run's persisted checkpoints.
class _ReplayBar extends StatelessWidget {
  const _ReplayBar({
    required this.checkpoints,
    required this.busy,
    required this.onReplay,
  });

  final List<Checkpoint> checkpoints;
  final bool busy;
  final ValueChanged<Checkpoint> onReplay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Icon(
            LucideIcons.history300,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'The last run saved ${checkpoints.length} '
              'checkpoint${checkpoints.length == 1 ? '' : 's'}.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          MenuAnchor(
            alignmentOffset: const Offset(0, 4),
            menuChildren: [
              for (final checkpoint in checkpoints)
                MenuItemButton(
                  onPressed: busy ? null : () => onReplay(checkpoint),
                  child: Text('After superstep ${checkpoint.superStep}'),
                ),
            ],
            builder: (context, menu, _) => TextButton.icon(
              onPressed: busy
                  ? null
                  : () => menu.isOpen ? menu.close() : menu.open(),
              icon: const Icon(LucideIcons.history300, size: 14),
              label: const Text('Replay'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The slim bar shown while a connection is selected.
class _EdgeBar extends StatelessWidget {
  const _EdgeBar({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Icon(
            LucideIcons.spline300,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          TextButton.icon(
            onPressed: onRemove,
            icon: const Icon(LucideIcons.x300, size: 14),
            label: const Text('Remove connection'),
          ),
        ],
      ),
    );
  }
}

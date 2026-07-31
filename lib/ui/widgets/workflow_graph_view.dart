// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/workflows/workflow_run_controller.dart';

const double _nodeWidth = 148;
const double _nodeHeight = 56;
const double _columnGap = 44;
const double _rowGap = 16;

/// A left-to-right rendering of a workflow graph with live node status.
///
/// Layout comes from [WorkflowRunController.layers] (columns by graph
/// depth); edges are painted beneath the node cards. Wide graphs scroll
/// horizontally rather than squeezing.
class WorkflowGraphView extends StatelessWidget {
  /// Creates a graph view over [controller]'s workflow.
  const WorkflowGraphView({required this.controller, super.key});

  /// The run whose graph and node states are shown.
  final WorkflowRunController controller;

  @override
  Widget build(BuildContext context) {
    final layers = controller.layers;
    if (layers.isEmpty) return const SizedBox.shrink();

    final columns = layers.length;
    final rows = layers.map((layer) => layer.length).reduce(
      (a, b) => a > b ? a : b,
    );
    final width = columns * _nodeWidth + (columns - 1) * _columnGap;
    final height = rows * _nodeHeight + (rows - 1) * _rowGap;

    final centers = <String, Offset>{};
    for (final (column, layer) in layers.indexed) {
      final layerHeight =
          layer.length * _nodeHeight + (layer.length - 1) * _rowGap;
      final top = (height - layerHeight) / 2;
      for (final (row, id) in layer.indexed) {
        centers[id] = Offset(
          column * (_nodeWidth + _columnGap) + _nodeWidth / 2,
          top + row * (_nodeHeight + _rowGap) + _nodeHeight / 2,
        );
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _EdgePainter(
                  edges: controller.edges,
                  centers: centers,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            for (final entry in centers.entries)
              Positioned(
                left: entry.value.dx - _nodeWidth / 2,
                top: entry.value.dy - _nodeHeight / 2,
                width: _nodeWidth,
                height: _nodeHeight,
                child: _NodeCard(
                  state:
                      controller.nodes[entry.key] ??
                      WorkflowNodeState(entry.key),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One executor rendered as a status-colored card.
class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.state});

  final WorkflowNodeState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (state.status) {
      WorkflowNodeStatus.idle => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
      ),
      WorkflowNodeStatus.running => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      WorkflowNodeStatus.done => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      WorkflowNodeStatus.failed => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };
    return Tooltip(
      message: state.error ?? state.id,
      waitDuration: const Duration(milliseconds: 500),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _StatusIcon(status: state.status, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                state.id,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final WorkflowNodeStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) => switch (status) {
    WorkflowNodeStatus.idle => Icon(
      LucideIcons.circleDashed300,
      size: 16,
      color: color,
    ),
    WorkflowNodeStatus.running => SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    ),
    WorkflowNodeStatus.done => Icon(
      LucideIcons.circleCheck300,
      size: 16,
      color: color,
    ),
    WorkflowNodeStatus.failed => Icon(
      LucideIcons.circleAlert300,
      size: 16,
      color: color,
    ),
  };
}

/// Paints the graph edges as arrowed curves between node borders.
class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.edges,
    required this.centers,
    required this.color,
  });

  final List<(String, String)> edges;
  final Map<String, Offset> centers;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final head = Paint()..color = color;

    for (final (sourceId, targetId) in edges) {
      final source = centers[sourceId];
      final target = centers[targetId];
      if (source == null || target == null) continue;
      final start = Offset(source.dx + _nodeWidth / 2, source.dy);
      final end = Offset(target.dx - _nodeWidth / 2 - 5, target.dy);
      final mid = (start.dx + end.dx) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(mid, start.dy, mid, end.dy, end.dx, end.dy),
        line,
      );
      canvas.drawPath(
        Path()
          ..moveTo(end.dx + 5, end.dy)
          ..lineTo(end.dx - 2, end.dy - 4)
          ..lineTo(end.dx - 2, end.dy + 4)
          ..close(),
        head,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) =>
      oldDelegate.edges != edges ||
      oldDelegate.centers != centers ||
      oldDelegate.color != color;
}

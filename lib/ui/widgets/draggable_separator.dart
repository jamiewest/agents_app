// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

/// A thin vertical drag handle between a resizable side panel and the main
/// content.
///
/// Reports horizontal drag deltas through [onDragUpdate]; the parent owns
/// the panel width. Shows a resize cursor and a primary-tinted line while
/// hovered so the affordance is discoverable without visual noise at rest.
class DraggableSeparator extends StatefulWidget {
  /// Creates a [DraggableSeparator].
  const DraggableSeparator({required this.onDragUpdate, super.key});

  /// Called with the horizontal drag delta in logical pixels.
  final ValueChanged<double> onDragUpdate;

  @override
  State<DraggableSeparator> createState() => _DraggableSeparatorState();
}

class _DraggableSeparatorState extends State<DraggableSeparator> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) =>
          widget.onDragUpdate(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: SizedBox(
          width: 8,
          child: Stack(
            children: [
              // Visually extends the panel so the handle reads as part of
              // its edge rather than a gap.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 4,
                child: ColoredBox(color: scheme.surfaceContainerLow),
              ),
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isHovered ? 4 : 0,
                  color: _isHovered ? scheme.primary : Colors.transparent,
                  height: double.infinity,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

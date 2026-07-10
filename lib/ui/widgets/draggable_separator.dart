// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A thin vertical drag handle between a resizable side panel and the main
/// content.
///
/// Reports horizontal drag deltas through [onDragUpdate]; the parent owns
/// the panel width. Shows a resize cursor and a primary-tinted line while
/// hovered or focused so the affordance is discoverable without visual noise
/// at rest. Keyboard users can focus the handle and resize with the
/// left/right arrow keys; assistive technology sees it as an adjustable
/// "Resize panel" control.
class DraggableSeparator extends StatefulWidget {
  /// Creates a [DraggableSeparator].
  const DraggableSeparator({required this.onDragUpdate, super.key});

  /// Called with the horizontal drag delta in logical pixels.
  final ValueChanged<double> onDragUpdate;

  /// How far one arrow-key press or semantic increase/decrease moves the
  /// separator, in logical pixels.
  static const double keyboardStep = 24;

  @override
  State<DraggableSeparator> createState() => _DraggableSeparatorState();
}

class _DraggableSeparatorState extends State<DraggableSeparator> {
  bool _isHovered = false;
  bool _isFocused = false;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -DraggableSeparator.keyboardStep,
      LogicalKeyboardKey.arrowRight => DraggableSeparator.keyboardStep,
      _ => null,
    };
    if (step == null) return KeyEventResult.ignored;
    widget.onDragUpdate(step);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _isHovered || _isFocused;
    return Semantics(
      label: 'Resize panel',
      slider: true,
      onIncrease: () => widget.onDragUpdate(DraggableSeparator.keyboardStep),
      onDecrease: () => widget.onDragUpdate(-DraggableSeparator.keyboardStep),
      child: Focus(
        onKeyEvent: _onKeyEvent,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        child: GestureDetector(
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
                      width: active ? 4 : 0,
                      color: active ? scheme.primary : Colors.transparent,
                      height: double.infinity,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

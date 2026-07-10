// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'draggable_separator.dart';

/// The hook descendants use to drive the app-level side panel hosted by
/// [SidePanelHost]: pages toggle it open with their own content, and the
/// panel slides in over the whole shell (navigation rail included).
class SidePanelScope extends InheritedWidget {
  /// Creates a [SidePanelScope].
  const SidePanelScope({
    required this.isOpen,
    required this.toggle,
    required this.close,
    required super.child,
    super.key,
  });

  /// Whether the panel is currently open (or opening).
  final bool isOpen;

  /// Opens the panel with [builder]'s content, or closes it if open.
  final void Function(WidgetBuilder builder) toggle;

  /// Slides the panel closed.
  final VoidCallback close;

  /// The nearest scope, or null when no [SidePanelHost] is above
  /// [context].
  static SidePanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidePanelScope>();

  @override
  bool updateShouldNotify(SidePanelScope oldWidget) =>
      isOpen != oldWidget.isOpen;
}

/// Hosts a right-anchored side panel that slides in OVER [child] — the
/// full shell, navigation rail and chat area alike — rather than pushing
/// content aside.
///
/// Content is supplied by whoever opens the panel through
/// [SidePanelScope.toggle], so the shell stays ignorant of what pages put
/// in it. The panel is resizable via a [DraggableSeparator] on its
/// leading edge and never exceeds the window width (narrow layouts get a
/// full-width sheet).
///
/// While open the panel behaves modally: the underlying shell is not
/// tappable, focusable, or visible to assistive technology; tapping outside
/// or pressing Escape closes it; focus moves into the panel on open and
/// returns to the invoking control on close.
class SidePanelHost extends StatefulWidget {
  /// Creates a [SidePanelHost].
  const SidePanelHost({required this.child, super.key});

  /// The content the panel overlays, typically the shell's adaptive
  /// layout.
  final Widget child;

  @override
  State<SidePanelHost> createState() => _SidePanelHostState();
}

class _SidePanelHostState extends State<SidePanelHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic));

  final FocusScopeNode _panelFocus = FocusScopeNode(
    debugLabel: 'SidePanelHost',
  );

  bool _open = false;
  double _width = 360;
  WidgetBuilder? _builder;
  FocusNode? _returnFocus;

  @override
  void initState() {
    super.initState();
    // The panel unmounts once the close animation settles; status changes
    // don't otherwise mark this element dirty.
    _controller.addStatusListener((_) => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  void _toggle(WidgetBuilder builder) {
    if (_open) {
      _close();
      return;
    }
    _returnFocus = FocusManager.instance.primaryFocus;
    setState(() {
      _builder = builder;
      _open = true;
    });
    _controller.forward();
    // Move focus into the panel once it is in the tree so keyboard and
    // screen-reader users land in what just opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _panelFocus.requestFocus();
    });
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _controller.reverse();
    final returnFocus = _returnFocus;
    _returnFocus = null;
    if (returnFocus != null &&
        returnFocus.context != null &&
        returnFocus.canRequestFocus) {
      returnFocus.requestFocus();
    }
  }

  KeyEventResult _onPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    _close();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => SidePanelScope(
    isOpen: _open,
    toggle: _toggle,
    close: _close,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = _width.clamp(0.0, constraints.maxWidth);
        return Stack(
          children: [
            // While the panel is open the underlying shell is inert: not
            // tappable, not reachable by focus traversal, and hidden from
            // assistive technology.
            ExcludeFocus(
              excluding: _open,
              child: ExcludeSemantics(
                excluding: _open,
                child: IgnorePointer(ignoring: _open, child: widget.child),
              ),
            ),
            if (_open)
              Positioned.fill(
                child: ModalBarrier(
                  dismissible: true,
                  onDismiss: _close,
                  color: null,
                ),
              ),
            if (!_controller.isDismissed && _builder != null)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: width,
                child: SlideTransition(
                  position: _slide,
                  child: FocusScope(
                    node: _panelFocus,
                    onKeyEvent: _onPanelKey,
                    child: Material(
                      elevation: 8,
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: SafeArea(
                        child: Row(
                          children: [
                            DraggableSeparator(
                              onDragUpdate: (deltaX) => setState(() {
                                _width = (_width - deltaX).clamp(
                                  280.0,
                                  constraints.maxWidth,
                                );
                              }),
                            ),
                            Expanded(child: Builder(builder: _builder!)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

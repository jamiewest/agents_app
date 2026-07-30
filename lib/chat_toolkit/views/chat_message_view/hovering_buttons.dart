import 'dart:async';

import 'package:flutter/material.dart' show IconButton, VisualDensity;
import 'package:flutter/widgets.dart';

import '../../styles/llm_chat_view_style.dart';
import '../../utility.dart';

/// A widget that displays hovering buttons for editing and copying.
///
/// The buttons appear at the bottom of the child widget on pointer hover or
/// when one of them holds keyboard focus, so they are reachable without a
/// mouse; screen readers can reach them at any time. Touch devices keep the
/// long-press context menu the message body provides.
class HoveringButtons extends StatefulWidget {
  /// Creates a [HoveringButtons] widget.
  ///
  /// The [onEdit] callback is invoked when the edit button is pressed. The
  /// [child] widget is the content over which the buttons will hover.
  const HoveringButtons({
    required this.chatStyle,
    required this.isUserMessage,
    required this.child,
    this.clipboardText,
    required this.clipboardMessage,
    this.onEdit,
    super.key,
  });

  /// The style information for the chat.
  final LlmChatViewStyle chatStyle;

  /// Whether the message is a user message.
  final bool isUserMessage;

  /// The text to be copied to the clipboard.
  final String? clipboardText;

  ///The text to be shown when copying to the clipboard.
  final String clipboardMessage;

  /// The child widget over which the buttons will hover.
  final Widget child;

  /// The callback to be invoked when the edit button is pressed.
  final VoidCallback? onEdit;

  @override
  State<HoveringButtons> createState() => _HoveringButtonsState();
}

class _HoveringButtonsState extends State<HoveringButtons> {
  static const _iconSize = 16;

  bool _hovering = false;
  bool _focused = false;

  bool get _visible => _hovering || _focused;

  @override
  Widget build(BuildContext context) {
    final chatStyle = widget.chatStyle;
    final paddedChild = Padding(
      padding: const EdgeInsets.only(bottom: _iconSize + 2),
      child: widget.child,
    );

    if (widget.clipboardText == null) return paddedChild;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          paddedChild,
          Positioned(
            bottom: 0,
            right: widget.isUserMessage ? 0 : null,
            left: widget.isUserMessage ? null : 32,
            // The buttons stay in the tree while hidden so keyboard focus
            // can reach them (focusing reveals them) and screen readers can
            // always activate them; pointer events are ignored until shown
            // to avoid invisible tap targets.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: IgnorePointer(
                ignoring: !_visible,
                child: Opacity(
                  opacity: _visible ? 1 : 0,
                  alwaysIncludeSemantics: true,
                  child: Row(
                    spacing: 6,
                    children: [
                      if (widget.onEdit != null)
                        _HoverActionButton(
                          icon: chatStyle.editButtonStyle!.icon,
                          iconSize: _iconSize.toDouble(),
                          // Theme-derived hover-action colors are designed
                          // for bare rendering; no inversion.
                          color: chatStyle.editButtonStyle!.iconColor,
                          label: chatStyle.editButtonStyle!.text,
                          onPressed: widget.onEdit!,
                        ),
                      _HoverActionButton(
                        icon: chatStyle.copyButtonStyle!.icon,
                        iconSize: 12,
                        color: chatStyle.copyButtonStyle!.iconColor,
                        label: chatStyle.copyButtonStyle!.text,
                        onPressed: () => unawaited(
                          copyToClipboard(
                            context,
                            widget.clipboardText!,
                            widget.clipboardMessage,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact focusable icon button for the hover-action row: keyboard
/// activation, a tooltip, and a semantic label the bare icons lacked.
class _HoverActionButton extends StatelessWidget {
  const _HoverActionButton({
    required this.icon,
    required this.iconSize,
    required this.color,
    required this.label,
    required this.onPressed,
  });

  final IconData? icon;
  final double iconSize;
  final Color? color;
  final String? label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: label,
    icon: Icon(icon, size: iconSize, color: color),
    iconSize: iconSize,
    padding: const EdgeInsets.all(2),
    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
    visualDensity: VisualDensity.compact,
  );
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

/// A widget that displays a Cupertino-style snack bar.
///
/// This widget creates an animated snack bar that slides up from the bottom of
/// the screen, displays a message for a specified duration, and then slides
/// back down.
///
/// The snack bar uses Cupertino styling to match iOS design guidelines.
@immutable
class CupertinoSnackBar extends StatefulWidget {
  /// Creates a [CupertinoSnackBar].
  ///
  /// * [message] is the text to display in the snack bar.
  /// * [animationDurationMillis] defines how long the slide animations take.
  /// * [waitDurationMillis] sets how long the snack bar stays visible before
  ///   dismissing.
  /// * [copyText] is the text copied to the clipboard when the copy button is
  ///   tapped. When null, no copy button is shown.
  /// * [copyLabel] is the tooltip/semantic label for the copy button.
  const CupertinoSnackBar({
    required this.message,
    required this.animationDurationMillis,
    required this.waitDurationMillis,
    this.copyText,
    this.copyLabel = 'Copy',
    super.key,
  });

  /// The message to display in the snack bar.
  final String message;

  /// The duration of the slide-in and slide-out animations in milliseconds.
  final int animationDurationMillis;

  /// The duration for which the snack bar remains visible in milliseconds.
  final int waitDurationMillis;

  /// The text copied to the clipboard when the copy button is tapped.
  ///
  /// When null, no copy button is shown.
  final String? copyText;

  /// The semantic label for the copy button.
  final String copyLabel;

  @override
  State<CupertinoSnackBar> createState() => _CupertinoSnackBarState();
}

class _CupertinoSnackBarState extends State<CupertinoSnackBar> {
  bool show = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => setState(() => show = true));
    Future.delayed(Duration(milliseconds: widget.waitDurationMillis), () {
      if (mounted) {
        setState(() => show = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedPositioned(
    bottom: show ? 8.0 : -50.0,
    left: 8,
    right: 8,
    curve: show ? Curves.linearToEaseOut : Curves.easeInToLinear,
    duration: Duration(milliseconds: widget.animationDurationMillis),
    child: CupertinoPopupSurface(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.message,
                style: const TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.secondaryLabel,
                ),
                textAlign: widget.copyText == null
                    ? TextAlign.center
                    : TextAlign.start,
              ),
            ),
            if (widget.copyText != null)
              CupertinoButton(
                padding: const EdgeInsets.only(left: 8),
                minimumSize: Size.zero,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.copyText!)),
                child: Semantics(
                  label: widget.copyLabel,
                  button: true,
                  child: const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

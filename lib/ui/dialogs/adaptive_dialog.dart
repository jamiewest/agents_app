// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, showCupertinoDialog;
import 'package:flutter/material.dart' show AlertDialog, TextButton, showDialog;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../utility.dart';

/// A utility class for showing adaptive dialogs that match the current platform
/// style.
@immutable
class AdaptiveAlertDialog {
  /// Displays an adaptive dialog with the specified [content] widget.
  ///
  /// This method selects a Cupertino-style dialog for iOS platforms and a
  /// Material-style dialog for other platforms, ensuring a consistent user
  /// experience across different devices.
  ///
  /// Parameters:
  ///   * [context]: The build context in which to display the dialog.
  ///   * [content]: The widget to be displayed as the dialog's content.
  ///   * [showOK]: A boolean flag indicating whether to display an "OK" button
  ///     in the dialog. Defaults to false. If false, the dialog will be
  ///     barrier dismissible.
  ///   * [copyText]: When non-null, the dialog shows a "Copy" button that
  ///     copies this text to the clipboard. Used to let users copy error
  ///     messages shown in [content].
  ///   * [copyLabel]: The label for the copy button. Defaults to `'Copy'`.
  ///
  /// Returns a [Future] that resolves with the result value when the dialog is
  /// dismissed.
  // NOTE: showOK is a fix for https://github.com/flutter/ai/issues/40.
  // Otherwise, the context used by Navigator.pop() is the wrong one.
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget content,
    bool showOK = false,
    String? copyText,
    String copyLabel = 'Copy',
  }) => isCupertinoApp(context)
      ? showCupertinoDialog<T>(
          context: context,
          barrierDismissible: !showOK,
          builder: (context) => CupertinoAlertDialog(
            content: content,
            actions: [
              if (copyText != null)
                CupertinoDialogAction(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: copyText)),
                  child: Text(copyLabel),
                ),
              if (showOK)
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
            ],
          ),
        )
      : showDialog<T>(
          context: context,
          barrierDismissible: !showOK,
          builder: (context) => Builder(
            builder: (context) {
              return AlertDialog(
                content: content,
                actions: [
                  if (copyText != null)
                    TextButton(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: copyText)),
                      child: Text(copyLabel),
                    ),
                  if (showOK)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                ],
              );
            },
          ),
        );
}

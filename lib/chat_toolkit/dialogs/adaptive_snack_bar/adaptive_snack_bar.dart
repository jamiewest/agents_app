// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart'
    show ScaffoldMessenger, SnackBar, SnackBarAction;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../../utility.dart';
import 'cupertino_snack_bar.dart';

/// A utility class for showing adaptive snack bars in Flutter applications.
///
/// This class provides a static method to display snack bars that adapt to the
/// current application environment, showing either a Material Design snack bar
/// or a Cupertino-style snack bar based on the app's context.
@immutable
class AdaptiveSnackBar {
  /// Shows an adaptive snack bar with the given message.
  ///
  /// This method determines whether the app is using Cupertino or Material
  /// design and displays an appropriate snack bar.
  ///
  /// Parameters:
  ///   * [context]: The build context in which to show the snack bar.
  ///   * [message]: The text message to display in the snack bar.
  ///   * [copyText]: When non-null, the snack bar shows a "Copy" action that
  ///     copies this text to the clipboard. Used to let users copy error
  ///     messages.
  ///   * [copyLabel]: The label for the copy action. Defaults to `'Copy'`.
  static void show(
    BuildContext context,
    String message, {
    String? copyText,
    String copyLabel = 'Copy',
  }) {
    if (isCupertinoApp(context)) {
      _showCupertinoSnackBar(
        context: context,
        message: message,
        copyText: copyText,
        copyLabel: copyLabel,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action: copyText == null
              ? null
              : SnackBarAction(
                  label: copyLabel,
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: copyText)),
                ),
        ),
      );
    }
  }

  static void _showCupertinoSnackBar({
    required BuildContext context,
    required String message,
    String? copyText,
    String copyLabel = 'Copy',
    int durationMillis = 4000,
  }) {
    const animationDurationMillis = 200;
    final overlayEntry = OverlayEntry(
      builder: (context) => CupertinoSnackBar(
        message: message,
        animationDurationMillis: animationDurationMillis,
        waitDurationMillis: durationMillis,
        copyText: copyText,
        copyLabel: copyLabel,
      ),
    );
    Future.delayed(
      Duration(milliseconds: durationMillis + 2 * animationDurationMillis),
      overlayEntry.remove,
    );
    Overlay.of(context).insert(overlayEntry);
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/material.dart' show IconButton, Tooltip;
import 'package:flutter/widgets.dart';

import '../styles/action_button_style.dart';
import '../utility.dart';

/// The minimum activation target for the button, per platform accessibility
/// guidance (44–48 logical pixels); the visual glyph stays [ActionButton.size].
const double _minTapTarget = 44;

/// A button widget with an icon.
///
/// This widget creates a button with a customizable icon, size, decoration, and
/// color. It can be enabled or disabled based on the presence of an [onPressed]
/// callback.
@immutable
class ActionButton extends StatelessWidget {
  /// Creates an [ActionButton].
  ///
  /// The [style] parameter must not be null.
  /// The [size] parameter defaults to 40 if not provided.
  const ActionButton({
    required this.onPressed,
    required this.style,
    super.key,
    this.size = 40,
  });

  /// The callback that is called when the button is tapped.
  /// If null, the button is disabled: not activatable and reported as
  /// disabled to assistive technology.
  final VoidCallback? onPressed;

  /// The style of the button.
  final ActionButtonStyle style;

  /// The diameter of the circular button's visual.
  final double size;

  @override
  Widget build(BuildContext context) {
    final visual = Container(
      width: size,
      height: size,
      decoration: style.iconDecoration,
      child: Icon(style.icon, color: style.iconColor, size: size * 0.6),
    );

    if (isCupertinoApp(context)) {
      // Tooltips aren't a thing in cupertino, so skip it. CupertinoButton
      // supplies focus and a 44px minimum interactive dimension; the label
      // gives screen readers the action name the icon alone doesn't.
      return Semantics(
        button: true,
        enabled: onPressed != null,
        label: style.text,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: visual,
        ),
      );
    }

    return Tooltip(
      message: style.text,
      textStyle: style.textStyle,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: _minTapTarget,
          minHeight: _minTapTarget,
        ),
        icon: visual,
      ),
    );
  }
}

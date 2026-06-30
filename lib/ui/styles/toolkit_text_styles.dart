// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart' show TextTheme, Theme;
import 'package:flutter/widgets.dart';

import 'toolkit_colors.dart';

/// Text styles used by the chat UI.
///
/// Defaults are derived from the host app's [TextTheme] so apps can provide
/// Google Fonts, bundled fonts, or platform fonts through their normal
/// [ThemeData].
@immutable
class ToolkitTextStyles {
  /// Creates a bundle of text styles for the chat UI.
  const ToolkitTextStyles({
    required this.display,
    required this.heading1,
    required this.heading2,
    required this.body1,
    required this.code,
    required this.body2,
    required this.tooltip,
    required this.filename,
    required this.filetype,
    required this.label,
    required this.link,
  });

  /// Creates chat text styles from the current [Theme].
  factory ToolkitTextStyles.fromTheme(BuildContext context) =>
      ToolkitTextStyles.fromTextTheme(Theme.of(context).textTheme);

  /// Creates chat text styles from a Flutter [TextTheme].
  factory ToolkitTextStyles.fromTextTheme(TextTheme textTheme) {
    final body = textTheme.bodyMedium ?? const TextStyle();
    final bodySmall = textTheme.bodySmall ?? body;

    final body1 = _style(
      textTheme.bodyLarge ?? body,
      color: ToolkitColors.enabledText,
      fontSize: 16,
      fontWeight: FontWeight.w400,
    );
    final body2 = _style(
      body,
      color: ToolkitColors.enabledText,
      fontSize: 14,
      fontWeight: FontWeight.w400,
    );
    final label = _style(
      bodySmall,
      color: ToolkitColors.enabledText,
      fontSize: 12,
      fontWeight: FontWeight.w400,
    );

    return ToolkitTextStyles(
      display: _style(
        textTheme.displaySmall ?? body,
        color: ToolkitColors.enabledText,
        fontSize: 32,
        fontWeight: FontWeight.w400,
      ),
      heading1: _style(
        textTheme.headlineSmall ?? body,
        color: ToolkitColors.enabledText,
        fontSize: 24,
        fontWeight: FontWeight.w400,
      ),
      heading2: _style(
        textTheme.titleLarge ?? body,
        color: ToolkitColors.enabledText,
        fontSize: 20,
        fontWeight: FontWeight.w400,
      ),
      body1: body1,
      code: _style(
        body,
        color: ToolkitColors.enabledText,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        fontFamily: 'monospace',
      ),
      body2: body2,
      tooltip: _style(
        body,
        color: ToolkitColors.tooltipText.withAlpha(230),
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
      filename: body2,
      filetype: body2.copyWith(color: ToolkitColors.hintText),
      label: label,
      link: body1.copyWith(
        color: ToolkitColors.link,
        decoration: TextDecoration.underline,
        decorationColor: ToolkitColors.link,
      ),
    );
  }

  /// Creates chat text styles without a host app theme.
  factory ToolkitTextStyles.fallback() =>
      ToolkitTextStyles.fromTextTheme(const TextTheme());

  static TextStyle _style(
    TextStyle base, {
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    String? fontFamily,
  }) => base.copyWith(
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontFamily: fontFamily ?? base.fontFamily,
  );

  /// Large display text style.
  final TextStyle display;

  /// Primary heading text style.
  final TextStyle heading1;

  /// Secondary heading text style.
  final TextStyle heading2;

  /// Primary body text style.
  final TextStyle body1;

  /// Code text style.
  final TextStyle code;

  /// Secondary body text style.
  final TextStyle body2;

  /// Tooltip text style.
  final TextStyle tooltip;

  /// Filename text style.
  final TextStyle filename;

  /// File type text style.
  final TextStyle filetype;

  /// Label text style.
  final TextStyle label;

  /// Link text style.
  final TextStyle link;
}

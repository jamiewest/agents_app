// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter/widgets.dart';

import 'toolkit_colors.dart';
import 'toolkit_text_styles.dart';

/// Style for the input text box.
@immutable
class ChatInputStyle {
  /// Creates an InputBoxStyle.
  const ChatInputStyle({
    this.textStyle,
    this.hintStyle,
    this.hintText,
    this.backgroundColor,
    this.decoration,
  });

  /// Merges the provided styles with the default styles.
  factory ChatInputStyle.resolve(
    ChatInputStyle? style, {
    ChatInputStyle? defaultStyle,
  }) {
    defaultStyle ??= ChatInputStyle.defaultStyle();
    return ChatInputStyle(
      textStyle: style?.textStyle ?? defaultStyle.textStyle,
      hintStyle: style?.hintStyle ?? defaultStyle.hintStyle,
      hintText: style?.hintText ?? defaultStyle.hintText,
      backgroundColor: style?.backgroundColor ?? defaultStyle.backgroundColor,
      decoration: style?.decoration ?? defaultStyle.decoration,
    );
  }

  /// Builds the style from a theme [ColorScheme]: a borderless filled
  /// pill sitting on the surface.
  factory ChatInputStyle.fromTheme(
    ColorScheme scheme,
    ToolkitTextStyles textStyles,
  ) => ChatInputStyle(
    textStyle: textStyles.body2.copyWith(color: scheme.onSurface),
    hintStyle: textStyles.body2.copyWith(color: scheme.onSurfaceVariant),
    hintText: 'Ask me anything...',
    backgroundColor: scheme.surface,
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
    ),
  );

  /// Provides a default style.
  factory ChatInputStyle.defaultStyle({ToolkitTextStyles? textStyles}) =>
      ChatInputStyle._lightStyle(textStyles ?? ToolkitTextStyles.fallback());

  /// Provides a default light style.
  factory ChatInputStyle._lightStyle(ToolkitTextStyles textStyles) =>
      ChatInputStyle(
        textStyle: textStyles.body2,
        hintStyle: textStyles.body2.copyWith(color: ToolkitColors.hintText),
        hintText: 'Ask me anything...',
        backgroundColor: ToolkitColors.containerBackground,
        decoration: BoxDecoration(
          color: ToolkitColors.containerBackground,
          border: Border.all(width: 1, color: ToolkitColors.outline),
          borderRadius: BorderRadius.circular(24),
        ),
      );

  /// The text style for the input text box.
  final TextStyle? textStyle;

  /// The hint text style for the input text box.
  final TextStyle? hintStyle;

  /// The hint text for the input text box.
  final String? hintText;

  /// The background color of the input box.
  final Color? backgroundColor;

  /// The decoration of the input box.
  final Decoration? decoration;
}

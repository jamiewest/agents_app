// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import '../strings/configured_agents_strings.dart';
import 'toolkit_colors.dart';
import 'toolkit_text_styles.dart';

/// Visual styling for the configured-agents UI.
///
/// Follows the same resolution pattern as `LlmChatViewStyle`: every field is
/// nullable, [resolve] fills gaps from a default style, [resolveFor] derives
/// text styles from the ambient [Theme], [defaultStyle] supplies safe defaults,
/// and [copyWith] overlays overrides.
@immutable
class ConfiguredAgentsStyle {
  /// Creates a [ConfiguredAgentsStyle].
  const ConfiguredAgentsStyle({
    this.backgroundColor,
    this.surfaceColor,
    this.dividerColor,
    this.accentColor,
    this.errorColor,
    this.titleTextStyle,
    this.subtitleTextStyle,
    this.bodyTextStyle,
    this.labelTextStyle,
    this.errorTextStyle,
    this.fieldDecoration,
    this.hintTextStyle,
    this.tilePadding,
    this.contentPadding,
    this.strings,
  });

  /// Resolves [style] against [defaultStyle], filling null fields.
  factory ConfiguredAgentsStyle.resolve(
    ConfiguredAgentsStyle? style, {
    ConfiguredAgentsStyle? defaultStyle,
    ToolkitTextStyles? textStyles,
  }) {
    textStyles ??= ToolkitTextStyles.fallback();
    defaultStyle ??= ConfiguredAgentsStyle.defaultStyle(textStyles: textStyles);
    return ConfiguredAgentsStyle(
      backgroundColor: style?.backgroundColor ?? defaultStyle.backgroundColor,
      surfaceColor: style?.surfaceColor ?? defaultStyle.surfaceColor,
      dividerColor: style?.dividerColor ?? defaultStyle.dividerColor,
      accentColor: style?.accentColor ?? defaultStyle.accentColor,
      errorColor: style?.errorColor ?? defaultStyle.errorColor,
      titleTextStyle: style?.titleTextStyle ?? defaultStyle.titleTextStyle,
      subtitleTextStyle:
          style?.subtitleTextStyle ?? defaultStyle.subtitleTextStyle,
      bodyTextStyle: style?.bodyTextStyle ?? defaultStyle.bodyTextStyle,
      labelTextStyle: style?.labelTextStyle ?? defaultStyle.labelTextStyle,
      errorTextStyle: style?.errorTextStyle ?? defaultStyle.errorTextStyle,
      fieldDecoration: style?.fieldDecoration ?? defaultStyle.fieldDecoration,
      hintTextStyle: style?.hintTextStyle ?? defaultStyle.hintTextStyle,
      tilePadding: style?.tilePadding ?? defaultStyle.tilePadding,
      contentPadding: style?.contentPadding ?? defaultStyle.contentPadding,
      strings: style?.strings ?? defaultStyle.strings,
    );
  }

  /// Resolves [style] using text styles derived from [context]'s [Theme].
  factory ConfiguredAgentsStyle.resolveFor(
    BuildContext context,
    ConfiguredAgentsStyle? style, {
    ConfiguredAgentsStyle? defaultStyle,
  }) {
    final textStyles = ToolkitTextStyles.fromTheme(context);
    return ConfiguredAgentsStyle.resolve(
      style,
      defaultStyle:
          defaultStyle ?? ConfiguredAgentsStyle.fromTheme(context, textStyles),
      textStyles: textStyles,
    );
  }

  /// Builds a style entirely from [context]'s [ColorScheme], so the
  /// configured-agents surfaces match the app theme in both brightnesses.
  factory ConfiguredAgentsStyle.fromTheme(
    BuildContext context,
    ToolkitTextStyles textStyles,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = TextStyle(color: scheme.onSurface);
    final onVariant = TextStyle(color: scheme.onSurfaceVariant);
    return ConfiguredAgentsStyle(
      backgroundColor: scheme.surface,
      surfaceColor: scheme.surfaceContainerLow,
      dividerColor: scheme.outlineVariant,
      accentColor: scheme.primary,
      errorColor: scheme.error,
      titleTextStyle: textStyles.heading2.merge(onSurface),
      subtitleTextStyle: textStyles.label.merge(onVariant),
      bodyTextStyle: textStyles.body1.merge(onSurface),
      labelTextStyle: textStyles.label.merge(onVariant),
      errorTextStyle: textStyles.label.copyWith(color: scheme.error),
      hintTextStyle: textStyles.body2.copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      fieldDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
    );
  }

  /// Provides default styling, optionally seeded from [textStyles].
  factory ConfiguredAgentsStyle.defaultStyle({ToolkitTextStyles? textStyles}) =>
      ConfiguredAgentsStyle._lightStyle(
        textStyles ?? ToolkitTextStyles.fallback(),
      );

  factory ConfiguredAgentsStyle._lightStyle(ToolkitTextStyles textStyles) =>
      ConfiguredAgentsStyle(
        backgroundColor: ToolkitColors.containerBackground,
        surfaceColor: ToolkitColors.containerBackground,
        dividerColor: ToolkitColors.outline,
        accentColor: ToolkitColors.darkButtonBackground,
        errorColor: ToolkitColors.red,
        titleTextStyle: textStyles.heading2,
        subtitleTextStyle: textStyles.label,
        bodyTextStyle: textStyles.body1,
        labelTextStyle: textStyles.label,
        errorTextStyle: textStyles.label.copyWith(color: ToolkitColors.red),
        fieldDecoration: BoxDecoration(
          color: ToolkitColors.containerBackground,
          border: Border.all(width: 1, color: ToolkitColors.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        hintTextStyle: textStyles.body2.copyWith(color: ToolkitColors.hintText),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        contentPadding: const EdgeInsets.all(16),
        strings: ConfiguredAgentsStrings.defaults,
      );

  /// Background color of the manager surface.
  final Color? backgroundColor;

  /// Background color of list tiles and form cards.
  final Color? surfaceColor;

  /// Divider/outline color.
  final Color? dividerColor;

  /// Accent color for primary actions.
  final Color? accentColor;

  /// Color used for error/validation emphasis.
  final Color? errorColor;

  /// Text style for primary titles (e.g. tile names, editor titles).
  final TextStyle? titleTextStyle;

  /// Text style for secondary/subtitle text.
  final TextStyle? subtitleTextStyle;

  /// Text style for body content.
  final TextStyle? bodyTextStyle;

  /// Text style for field labels.
  final TextStyle? labelTextStyle;

  /// Text style for validation/error text.
  final TextStyle? errorTextStyle;

  /// Decoration applied to text fields.
  final Decoration? fieldDecoration;

  /// Text style for field hints/placeholders.
  final TextStyle? hintTextStyle;

  /// Padding inside list tiles.
  final EdgeInsetsGeometry? tilePadding;

  /// Padding around editor content.
  final EdgeInsetsGeometry? contentPadding;

  /// Custom strings for the configured-agents UI.
  final ConfiguredAgentsStrings? strings;

  /// Returns a copy with the given fields replaced.
  ConfiguredAgentsStyle copyWith({
    Color? backgroundColor,
    Color? surfaceColor,
    Color? dividerColor,
    Color? accentColor,
    Color? errorColor,
    TextStyle? titleTextStyle,
    TextStyle? subtitleTextStyle,
    TextStyle? bodyTextStyle,
    TextStyle? labelTextStyle,
    TextStyle? errorTextStyle,
    Decoration? fieldDecoration,
    TextStyle? hintTextStyle,
    EdgeInsetsGeometry? tilePadding,
    EdgeInsetsGeometry? contentPadding,
    ConfiguredAgentsStrings? strings,
  }) => ConfiguredAgentsStyle(
    backgroundColor: backgroundColor ?? this.backgroundColor,
    surfaceColor: surfaceColor ?? this.surfaceColor,
    dividerColor: dividerColor ?? this.dividerColor,
    accentColor: accentColor ?? this.accentColor,
    errorColor: errorColor ?? this.errorColor,
    titleTextStyle: titleTextStyle ?? this.titleTextStyle,
    subtitleTextStyle: subtitleTextStyle ?? this.subtitleTextStyle,
    bodyTextStyle: bodyTextStyle ?? this.bodyTextStyle,
    labelTextStyle: labelTextStyle ?? this.labelTextStyle,
    errorTextStyle: errorTextStyle ?? this.errorTextStyle,
    fieldDecoration: fieldDecoration ?? this.fieldDecoration,
    hintTextStyle: hintTextStyle ?? this.hintTextStyle,
    tilePadding: tilePadding ?? this.tilePadding,
    contentPadding: contentPadding ?? this.contentPadding,
    strings: strings ?? this.strings,
  );
}

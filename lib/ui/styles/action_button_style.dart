// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter/widgets.dart';

import '../strings/llm_chat_view_strings.dart';
import 'action_button_type.dart';
import 'tookit_icons.dart';
import 'toolkit_colors.dart';
import 'toolkit_text_styles.dart';

/// Style for icon buttons.
@immutable
class ActionButtonStyle {
  /// Creates an IconButtonStyle.
  const ActionButtonStyle({
    this.icon,
    this.iconColor,
    this.iconDecoration,
    this.text,
    this.textStyle,
  });

  /// Resolves the provided [style] with the [defaultStyle].
  ///
  /// This method returns a new [ActionButtonStyle] instance where each property
  /// is taken from the provided [style] if it is not null, otherwise from the
  /// [defaultStyle].
  ///
  /// - [style]: The style to resolve. If null, the [defaultStyle] will be used.
  /// - [defaultStyle]: The default style to use for any properties not provided
  ///   by the [style].
  factory ActionButtonStyle.resolve(
    ActionButtonStyle? style, {
    required ActionButtonStyle defaultStyle,
  }) => ActionButtonStyle(
    icon: style?.icon ?? defaultStyle.icon,
    iconColor: style?.iconColor ?? defaultStyle.iconColor,
    iconDecoration: style?.iconDecoration ?? defaultStyle.iconDecoration,
    text: style?.text ?? defaultStyle.text,
    textStyle: style?.textStyle ?? defaultStyle.textStyle,
  );

  /// Provides default style for icon buttons.
  factory ActionButtonStyle.defaultStyle(
    ActionButtonType type, {
    LlmChatViewStrings? strings,
    ToolkitTextStyles? textStyles,
  }) {
    final resolvedStrings = strings ?? LlmChatViewStrings.defaults;
    return ActionButtonStyle._lightStyle(
      type,
      resolvedStrings,
      textStyles ?? ToolkitTextStyles.fallback(),
    );
  }

  /// Builds the style for [type] from a theme [ColorScheme].
  ///
  /// Same icons and tooltip text as [defaultStyle]; every color comes from
  /// scheme roles so buttons read correctly in both brightnesses.
  factory ActionButtonStyle.fromTheme(
    ActionButtonType type,
    ColorScheme scheme,
    ToolkitTextStyles textStyles, {
    LlmChatViewStrings? strings,
  }) {
    final base = ActionButtonStyle.defaultStyle(
      type,
      strings: strings,
      textStyles: textStyles,
    );
    final (Color color, Color background, bool menuItem) = switch (type) {
      // The primary send/stop affordance: an M3 filled icon button.
      ActionButtonType.submit ||
      ActionButtonType.stop => (scheme.onPrimary, scheme.primary, false),
      ActionButtonType.disabled => (
        scheme.onSurface.withValues(alpha: 0.38),
        scheme.onSurface.withValues(alpha: 0.12),
        false,
      ),
      ActionButtonType.close ||
      ActionButtonType.cancel ||
      ActionButtonType.closeMenu => (
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
        false,
      ),
      ActionButtonType.add || ActionButtonType.record => (
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
        false,
      ),
      // Menu rows and hover actions: plain icons, no fill.
      ActionButtonType.attachFile ||
      ActionButtonType.camera ||
      ActionButtonType.gallery ||
      ActionButtonType.url => (
        scheme.onSurfaceVariant,
        const Color(0x00000000),
        true,
      ),
      ActionButtonType.copy || ActionButtonType.edit => (
        scheme.onSurfaceVariant,
        const Color(0x00000000),
        false,
      ),
    };
    return ActionButtonStyle(
      icon: base.icon,
      iconColor: color,
      iconDecoration: BoxDecoration(color: background, shape: BoxShape.circle),
      text: base.text,
      textStyle: menuItem
          ? textStyles.body2.copyWith(color: scheme.onSurface)
          : textStyles.tooltip,
    );
  }

  /// Provides default light style for icon buttons.
  factory ActionButtonStyle._lightStyle(
    ActionButtonType type,
    LlmChatViewStrings strings,
    ToolkitTextStyles textStyles,
  ) {
    IconData? icon;
    var color = ToolkitColors.darkIcon;
    var bgColor = ToolkitColors.lightButtonBackground;
    String text = '';
    TextStyle? textStyle = textStyles.tooltip;

    switch (type) {
      case ActionButtonType.add:
        icon = ToolkitIcons.add;
        text = strings.addAttachment;
      case ActionButtonType.attachFile:
        icon = ToolkitIcons.attach_file;
        color = ToolkitColors.darkIcon;
        bgColor = ToolkitColors.transparent;
        text = strings.attachFile;
        textStyle = textStyles.body2;
      case ActionButtonType.camera:
        icon = ToolkitIcons.camera_alt;
        color = ToolkitColors.darkIcon;
        bgColor = ToolkitColors.transparent;
        text = strings.takePhoto;
        textStyle = textStyles.body2;
      case ActionButtonType.stop:
        icon = ToolkitIcons.stop;
        text = strings.stop;
      case ActionButtonType.close:
        icon = ToolkitIcons.close;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.darkButtonBackground;
        text = strings.close;
      case ActionButtonType.cancel:
        icon = ToolkitIcons.close;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.darkButtonBackground;
        text = strings.cancel;
      case ActionButtonType.copy:
        icon = ToolkitIcons.content_copy;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.darkButtonBackground;
        text = strings.copyToClipboard;
      case ActionButtonType.edit:
        icon = ToolkitIcons.edit;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.darkButtonBackground;
        text = strings.editMessage;
      case ActionButtonType.gallery:
        icon = ToolkitIcons.image;
        color = ToolkitColors.darkIcon;
        bgColor = ToolkitColors.transparent;
        text = strings.attachImage;
        textStyle = textStyles.body2;
      case ActionButtonType.record:
        icon = ToolkitIcons.mic;
        text = strings.recordAudio;
      case ActionButtonType.submit:
        icon = ToolkitIcons.submit_icon;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.darkButtonBackground;
        text = strings.submitMessage;
      case ActionButtonType.disabled:
        icon = ToolkitIcons.submit_icon;
        color = ToolkitColors.darkIcon;
        bgColor = ToolkitColors.disabledButton;
        text = '';
      case ActionButtonType.closeMenu:
        icon = ToolkitIcons.close;
        color = ToolkitColors.whiteIcon;
        bgColor = ToolkitColors.greyBackground;
        text = strings.closeMenu;
      case ActionButtonType.url:
        icon = null; // Placeholder for URL icon
        color = ToolkitColors.darkIcon;
        bgColor = ToolkitColors.transparent;
        text = strings.attachFile;
        textStyle = textStyles.body2;
    }

    return ActionButtonStyle(
      icon: icon,
      iconColor: color,
      iconDecoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      text: text,
      textStyle: textStyle,
    );
  }

  /// The icon to display for the icon button.
  final IconData? icon;

  /// The color of the icon.
  final Color? iconColor;

  /// The decoration for the icon.
  final Decoration? iconDecoration;

  /// The tooltip for the icon button (could be menu item text or a tooltip).
  final String? text;

  /// The text style of the tooltip.
  final TextStyle? textStyle;
}

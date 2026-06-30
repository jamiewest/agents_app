// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import '../strings/strings.dart';
import 'action_button_style.dart';
import 'action_button_type.dart';
import 'chat_input_style.dart';
import 'file_attachment_style.dart';
import 'llm_message_style.dart';
import 'suggestion_style.dart';
import 'toolkit_colors.dart';
import 'toolkit_text_styles.dart';
import 'user_message_style.dart';
import 'waveform_recorder_style.dart';

/// Style for the entire chat widget.
@immutable
class LlmChatViewStyle {
  /// Creates a style object for the chat widget.
  const LlmChatViewStyle({
    this.backgroundColor,
    this.menuColor,
    this.progressIndicatorColor,
    this.userMessageStyle,
    this.llmMessageStyle,
    this.chatInputStyle,
    this.addButtonStyle,
    this.attachFileButtonStyle,
    this.cameraButtonStyle,
    this.stopButtonStyle,
    this.closeButtonStyle,
    this.cancelButtonStyle,
    this.copyButtonStyle,
    this.editButtonStyle,
    this.galleryButtonStyle,
    this.recordButtonStyle,
    this.submitButtonStyle,
    this.disabledButtonStyle,
    this.closeMenuButtonStyle,
    this.actionButtonBarDecoration,
    this.fileAttachmentStyle,
    this.suggestionStyle,
    this.voiceNoteRecorderStyle,
    this.urlButtonStyle,
    this.padding,
    this.margin,
    this.messageSpacing,
    this.strings,
  });

  /// Resolves the provided [style] with the [defaultStyle].
  ///
  /// This method returns a new [LlmChatViewStyle] instance where each property
  /// is taken from the provided [style] if it is not null, otherwise from the
  /// [defaultStyle].
  ///
  /// - [style]: The style to resolve. If null, the [defaultStyle] will be used.
  /// - [defaultStyle]: The default style to use for any properties not provided
  ///   by the [style].
  factory LlmChatViewStyle.resolve(
    LlmChatViewStyle? style, {
    LlmChatViewStyle? defaultStyle,
    ToolkitTextStyles? textStyles,
  }) {
    textStyles ??= ToolkitTextStyles.fallback();
    defaultStyle ??= LlmChatViewStyle.defaultStyle(textStyles: textStyles);
    return LlmChatViewStyle(
      backgroundColor: style?.backgroundColor ?? defaultStyle.backgroundColor,
      menuColor: style?.menuColor ?? defaultStyle.menuColor,
      progressIndicatorColor:
          style?.progressIndicatorColor ?? defaultStyle.progressIndicatorColor,
      userMessageStyle: UserMessageStyle.resolve(
        style?.userMessageStyle,
        defaultStyle: defaultStyle.userMessageStyle,
      ),
      llmMessageStyle: LlmMessageStyle.resolve(
        style?.llmMessageStyle,
        defaultStyle: defaultStyle.llmMessageStyle,
      ),
      chatInputStyle: ChatInputStyle.resolve(
        style?.chatInputStyle,
        defaultStyle: defaultStyle.chatInputStyle,
      ),
      addButtonStyle: ActionButtonStyle.resolve(
        style?.addButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.addButtonStyle,
          ActionButtonType.add,
          style?.strings,
          textStyles,
        ),
      ),
      attachFileButtonStyle: ActionButtonStyle.resolve(
        style?.attachFileButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.attachFileButtonStyle,
          ActionButtonType.attachFile,
          style?.strings,
          textStyles,
        ),
      ),
      cameraButtonStyle: ActionButtonStyle.resolve(
        style?.cameraButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.cameraButtonStyle,
          ActionButtonType.camera,
          style?.strings,
          textStyles,
        ),
      ),
      stopButtonStyle: ActionButtonStyle.resolve(
        style?.stopButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.stopButtonStyle,
          ActionButtonType.stop,
          style?.strings,
          textStyles,
        ),
      ),
      closeButtonStyle: ActionButtonStyle.resolve(
        style?.closeButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.closeButtonStyle,
          ActionButtonType.close,
          style?.strings,
          textStyles,
        ),
      ),
      cancelButtonStyle: ActionButtonStyle.resolve(
        style?.cancelButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.cancelButtonStyle,
          ActionButtonType.cancel,
          style?.strings,
          textStyles,
        ),
      ),
      copyButtonStyle: ActionButtonStyle.resolve(
        style?.copyButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.copyButtonStyle,
          ActionButtonType.copy,
          style?.strings,
          textStyles,
        ),
      ),
      editButtonStyle: ActionButtonStyle.resolve(
        style?.editButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.editButtonStyle,
          ActionButtonType.edit,
          style?.strings,
          textStyles,
        ),
      ),
      galleryButtonStyle: ActionButtonStyle.resolve(
        style?.galleryButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.galleryButtonStyle,
          ActionButtonType.gallery,
          style?.strings,
          textStyles,
        ),
      ),
      recordButtonStyle: ActionButtonStyle.resolve(
        style?.recordButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.recordButtonStyle,
          ActionButtonType.record,
          style?.strings,
          textStyles,
        ),
      ),
      submitButtonStyle: ActionButtonStyle.resolve(
        style?.submitButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.submitButtonStyle,
          ActionButtonType.submit,
          style?.strings,
          textStyles,
        ),
      ),
      disabledButtonStyle: ActionButtonStyle.resolve(
        style?.disabledButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.disabledButtonStyle,
          ActionButtonType.disabled,
          style?.strings,
          textStyles,
        ),
      ),
      closeMenuButtonStyle: ActionButtonStyle.resolve(
        style?.closeMenuButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.closeMenuButtonStyle,
          ActionButtonType.closeMenu,
          style?.strings,
          textStyles,
        ),
      ),
      actionButtonBarDecoration:
          style?.actionButtonBarDecoration ??
          defaultStyle.actionButtonBarDecoration,
      suggestionStyle: SuggestionStyle.resolve(
        style?.suggestionStyle,
        defaultStyle: defaultStyle.suggestionStyle,
      ),
      fileAttachmentStyle: FileAttachmentStyle.resolve(
        style?.fileAttachmentStyle,
        defaultStyle: defaultStyle.fileAttachmentStyle,
      ),
      voiceNoteRecorderStyle: VoiceNoteRecorderStyle.resolve(
        style?.voiceNoteRecorderStyle,
        defaultStyle: defaultStyle.voiceNoteRecorderStyle,
      ),
      urlButtonStyle: ActionButtonStyle.resolve(
        style?.urlButtonStyle,
        defaultStyle: _defaultActionButtonStyle(
          defaultStyle.urlButtonStyle,
          ActionButtonType.url,
          style?.strings,
          textStyles,
        ),
      ),
      padding: style?.padding ?? defaultStyle.padding,
      margin: style?.margin ?? defaultStyle.margin,
      messageSpacing: style?.messageSpacing ?? defaultStyle.messageSpacing,
      strings: style?.strings ?? defaultStyle.strings,
    );
  }

  /// Resolves the provided [style] against text styles from [context].
  factory LlmChatViewStyle.resolveFor(
    BuildContext context,
    LlmChatViewStyle? style, {
    LlmChatViewStyle? defaultStyle,
  }) {
    final textStyles = ToolkitTextStyles.fromTheme(context);
    return LlmChatViewStyle.resolve(
      style,
      defaultStyle:
          defaultStyle ?? LlmChatViewStyle.defaultStyle(textStyles: textStyles),
      textStyles: textStyles,
    );
  }

  static ActionButtonStyle _defaultActionButtonStyle(
    ActionButtonStyle? defaultStyle,
    ActionButtonType type,
    LlmChatViewStrings? strings,
    ToolkitTextStyles textStyles,
  ) => strings == null && defaultStyle != null
      ? defaultStyle
      : ActionButtonStyle.defaultStyle(
          type,
          strings: strings,
          textStyles: textStyles,
        );

  /// Provides default style if none is specified.
  factory LlmChatViewStyle.defaultStyle({ToolkitTextStyles? textStyles}) =>
      LlmChatViewStyle._lightStyle(textStyles ?? ToolkitTextStyles.fallback());

  /// Provides a default light style.
  factory LlmChatViewStyle._lightStyle(ToolkitTextStyles textStyles) =>
      LlmChatViewStyle(
        backgroundColor: ToolkitColors.containerBackground,
        menuColor: ToolkitColors.containerBackground,
        progressIndicatorColor: ToolkitColors.black,
        userMessageStyle: UserMessageStyle.defaultStyle(textStyles: textStyles),
        llmMessageStyle: LlmMessageStyle.defaultStyle(textStyles: textStyles),
        chatInputStyle: ChatInputStyle.defaultStyle(textStyles: textStyles),
        addButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.add,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        stopButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.stop,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        recordButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.record,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        submitButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.submit,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        closeMenuButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.closeMenu,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        attachFileButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.attachFile,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        galleryButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.gallery,
          textStyles: textStyles,
        ),
        cameraButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.camera,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        closeButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.close,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        cancelButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.cancel,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        copyButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.copy,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        editButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.edit,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        actionButtonBarDecoration: BoxDecoration(
          color: ToolkitColors.darkButtonBackground,
          borderRadius: BorderRadius.circular(20),
        ),
        fileAttachmentStyle: FileAttachmentStyle.defaultStyle(
          textStyles: textStyles,
        ),
        suggestionStyle: SuggestionStyle.defaultStyle(textStyles: textStyles),
        voiceNoteRecorderStyle: VoiceNoteRecorderStyle.defaultStyle(),
        urlButtonStyle: ActionButtonStyle.defaultStyle(
          ActionButtonType.url,
          strings: LlmChatViewStrings.defaults,
          textStyles: textStyles,
        ),
        strings: LlmChatViewStrings.defaults,
      );

  /// Creates a copy of this style with the given fields replaced by the new
  LlmChatViewStyle copyWith({
    Color? backgroundColor,
    Color? menuColor,
    Color? progressIndicatorColor,
    UserMessageStyle? userMessageStyle,
    LlmMessageStyle? llmMessageStyle,
    ChatInputStyle? chatInputStyle,
    ActionButtonStyle? addButtonStyle,
    ActionButtonStyle? attachFileButtonStyle,
    ActionButtonStyle? cameraButtonStyle,
    ActionButtonStyle? stopButtonStyle,
    ActionButtonStyle? closeButtonStyle,
    ActionButtonStyle? cancelButtonStyle,
    ActionButtonStyle? copyButtonStyle,
    ActionButtonStyle? editButtonStyle,
    ActionButtonStyle? galleryButtonStyle,
    ActionButtonStyle? recordButtonStyle,
    ActionButtonStyle? submitButtonStyle,
    ActionButtonStyle? disabledButtonStyle,
    ActionButtonStyle? closeMenuButtonStyle,
    Decoration? actionButtonBarDecoration,
    FileAttachmentStyle? fileAttachmentStyle,
    SuggestionStyle? suggestionStyle,
    VoiceNoteRecorderStyle? voiceNoteRecorderStyle,
    ActionButtonStyle? urlButtonStyle,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    double? messageSpacing,
    LlmChatViewStrings? strings,
  }) {
    return LlmChatViewStyle(
      backgroundColor: backgroundColor ?? this.backgroundColor,
      menuColor: menuColor ?? this.menuColor,
      progressIndicatorColor:
          progressIndicatorColor ?? this.progressIndicatorColor,
      userMessageStyle: userMessageStyle ?? this.userMessageStyle,
      llmMessageStyle: llmMessageStyle ?? this.llmMessageStyle,
      chatInputStyle: chatInputStyle ?? this.chatInputStyle,
      addButtonStyle: addButtonStyle ?? this.addButtonStyle,
      attachFileButtonStyle:
          attachFileButtonStyle ?? this.attachFileButtonStyle,
      cameraButtonStyle: cameraButtonStyle ?? this.cameraButtonStyle,
      stopButtonStyle: stopButtonStyle ?? this.stopButtonStyle,
      closeButtonStyle: closeButtonStyle ?? this.closeButtonStyle,
      cancelButtonStyle: cancelButtonStyle ?? this.cancelButtonStyle,
      copyButtonStyle: copyButtonStyle ?? this.copyButtonStyle,
      editButtonStyle: editButtonStyle ?? this.editButtonStyle,
      galleryButtonStyle: galleryButtonStyle ?? this.galleryButtonStyle,
      recordButtonStyle: recordButtonStyle ?? this.recordButtonStyle,
      submitButtonStyle: submitButtonStyle ?? this.submitButtonStyle,
      disabledButtonStyle: disabledButtonStyle ?? this.disabledButtonStyle,
      closeMenuButtonStyle: closeMenuButtonStyle ?? this.closeMenuButtonStyle,
      actionButtonBarDecoration:
          actionButtonBarDecoration ?? this.actionButtonBarDecoration,
      fileAttachmentStyle: fileAttachmentStyle ?? this.fileAttachmentStyle,
      suggestionStyle: suggestionStyle ?? this.suggestionStyle,
      voiceNoteRecorderStyle:
          voiceNoteRecorderStyle ?? this.voiceNoteRecorderStyle,
      urlButtonStyle: urlButtonStyle ?? this.urlButtonStyle,
      padding: padding ?? this.padding,
      margin: margin ?? this.margin,
      messageSpacing: messageSpacing ?? this.messageSpacing,
      strings: strings ?? this.strings,
    );
  }

  /// Background color of the entire chat widget.
  final Color? backgroundColor;

  /// The color of the menu.
  final Color? menuColor;

  /// The color of the progress indicator.
  final Color? progressIndicatorColor;

  /// Style for user messages.
  final UserMessageStyle? userMessageStyle;

  /// Style for LLM messages.
  final LlmMessageStyle? llmMessageStyle;

  /// Style for the input text box.
  final ChatInputStyle? chatInputStyle;

  /// Style for the add button.
  final ActionButtonStyle? addButtonStyle;

  /// Style for the attach file button.
  final ActionButtonStyle? attachFileButtonStyle;

  /// Style for the camera button.
  final ActionButtonStyle? cameraButtonStyle;

  /// Style for the stop button.
  final ActionButtonStyle? stopButtonStyle;

  /// Style for the close button.
  final ActionButtonStyle? closeButtonStyle;

  /// Style for the cancel button.
  final ActionButtonStyle? cancelButtonStyle;

  /// Style for the copy button.
  final ActionButtonStyle? copyButtonStyle;

  /// Style for the edit button.
  final ActionButtonStyle? editButtonStyle;

  /// Style for the gallery button.
  final ActionButtonStyle? galleryButtonStyle;

  /// Style for the record button.
  final ActionButtonStyle? recordButtonStyle;

  /// Style for the submit button.
  final ActionButtonStyle? submitButtonStyle;

  /// Style for the disabled button.
  final ActionButtonStyle? disabledButtonStyle;

  /// Style for the close menu button.
  final ActionButtonStyle? closeMenuButtonStyle;

  /// Decoration for the action button bar.
  final Decoration? actionButtonBarDecoration;

  /// Style for file attachments.
  final FileAttachmentStyle? fileAttachmentStyle;

  /// Style for suggestions.
  final SuggestionStyle? suggestionStyle;

  /// Style for the waveform recorder.
  final VoiceNoteRecorderStyle? voiceNoteRecorderStyle;

  /// Style for the URL button.
  final ActionButtonStyle? urlButtonStyle;

  /// Default padding around the chat view.
  final EdgeInsetsGeometry? padding;

  /// Margin around the entire chat view.
  final EdgeInsetsGeometry? margin;

  /// Spacing between messages.
  final double? messageSpacing;

  /// Custom strings for the chat view.
  final LlmChatViewStrings? strings;
}

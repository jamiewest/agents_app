// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import '../providers/interface/chat_message.dart';
import '../styles/llm_chat_view_style.dart';

import '../chat_view_model/chat_view_model_client.dart';
import 'chat_message_view/llm_message_view.dart';
import 'chat_message_view/user_message_view.dart';
import 'chat_welcome_view.dart';

/// A widget that displays a history of chat messages.
///
/// This widget renders a scrollable list of chat messages, supporting
/// selection and editing of messages. It displays messages in reverse
/// chronological order (newest at the bottom).
@immutable
class ChatHistoryView extends StatefulWidget {
  /// Creates a [ChatHistoryView].
  ///
  /// If [onEditMessage] is provided, it will be called when a user initiates an
  /// edit action on an editable message (typically the last user message in the
  /// history).
  const ChatHistoryView({
    this.onEditMessage,
    required this.onSelectSuggestion,
    super.key,
  });

  /// Optional callback function for editing a message.
  ///
  /// If provided, this function will be called when a user initiates an edit
  /// action on an editable message (typically the last user message in the
  /// history). The function receives the [ChatMessage] to be edited as its
  /// parameter.
  final void Function(ChatMessage message)? onEditMessage;

  /// The callback function to call when a suggestion is selected.
  final void Function(String suggestion) onSelectSuggestion;

  @override
  State<ChatHistoryView> createState() => _ChatHistoryViewState();
}

class _ChatHistoryViewState extends State<ChatHistoryView> {
  @override
  Widget build(BuildContext context) => ChatViewModelClient(
    builder: (context, viewModel, child) {
      final chatStyle = LlmChatViewStyle.resolveFor(context, viewModel.style);
      final padding =
          chatStyle.padding as EdgeInsets? ??
          const EdgeInsets.only(top: 16, left: 16, right: 16);
      final messageSpacing = chatStyle.messageSpacing ?? 6.0;

      final history = viewModel.provider.history.toList();

      if (history.isEmpty &&
          (viewModel.welcomeMessage != null ||
              viewModel.suggestions.isNotEmpty)) {
        return ChatWelcomeView(
          welcomeMessage: viewModel.welcomeMessage,
          suggestions: viewModel.suggestions,
          onSelectSuggestion: widget.onSelectSuggestion,
        );
      }

      return ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.08, 0.94, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: Padding(
          padding: padding,
          child: ListView.builder(
            reverse: true,
            // Lifts the newest message's resting position above the bottom
            // fade so its token-detail row isn't dimmed, while scrolled
            // content still passes through the fade zone.
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: history.length,
            itemBuilder: (context, index) {
              final messageIndex = history.length - index - 1;
              final message = history[messageIndex];
              final isLastUserMessage =
                  message.origin.isUser && messageIndex >= history.length - 2;
              final canEdit = isLastUserMessage && widget.onEditMessage != null;
              final isUser = message.origin.isUser;

              return Padding(
                padding: EdgeInsets.only(top: messageSpacing),
                child: isUser
                    ? UserMessageView(
                        message,
                        onEdit: canEdit
                            ? () => widget.onEditMessage?.call(message)
                            : null,
                      )
                    : LlmMessageView(message),
              );
            },
          ),
        ),
      );
    },
  );
}

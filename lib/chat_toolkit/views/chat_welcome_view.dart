// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import '../chat_view_model/chat_view_model_client.dart';
import '../styles/llm_chat_view_style.dart';

/// A centered greeting shown in place of the transcript while a
/// conversation has no messages yet.
///
/// Renders a tonal avatar, the optional [welcomeMessage], and tappable
/// suggestion chips. Once the first message lands, [ChatWelcomeView] is
/// replaced by the regular message list.
@immutable
class ChatWelcomeView extends StatelessWidget {
  /// Creates a [ChatWelcomeView].
  const ChatWelcomeView({
    required this.welcomeMessage,
    required this.suggestions,
    required this.onSelectSuggestion,
    super.key,
  });

  /// The greeting to display, if any.
  final String? welcomeMessage;

  /// Prompt suggestions rendered as chips below the greeting.
  final List<String> suggestions;

  /// Called with the tapped suggestion's text.
  final void Function(String suggestion) onSelectSuggestion;

  @override
  Widget build(BuildContext context) => ChatViewModelClient(
    builder: (context, viewModel, child) {
      final chatStyle = LlmChatViewStyle.resolveFor(context, viewModel.style);
      final llmStyle = chatStyle.llmMessageStyle!;
      final suggestionStyle = chatStyle.suggestionStyle!;
      final scheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;

      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 48,
                  width: 48,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    llmStyle.icon,
                    size: 24,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                if (welcomeMessage case final message?) ...[
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: textTheme.headlineSmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ],
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final suggestion in suggestions)
                        GestureDetector(
                          onTap: () => onSelectSuggestion(suggestion),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: suggestionStyle.decoration,
                            child: Text(
                              suggestion,
                              softWrap: true,
                              maxLines: 3,
                              style: suggestionStyle.textStyle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

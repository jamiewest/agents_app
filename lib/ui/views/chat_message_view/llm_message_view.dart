// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions/ai.dart' show UsageDetails;
import 'package:flutter/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../chat_view_model/chat_view_model_client.dart';
import '../../providers/interface/chat_message.dart';
import '../../styles/llm_chat_view_style.dart';
import '../jumping_dots_progress_indicator/jumping_dots_progress_indicator.dart';
import 'adaptive_copy_text.dart';
import 'hovering_buttons.dart';

/// A widget that displays an LLM (Language Model) message in a chat interface.
@immutable
class LlmMessageView extends StatelessWidget {
  /// Creates an [LlmMessageView].
  ///
  /// The [message] parameter is required and represents the LLM chat message to
  /// be displayed.
  const LlmMessageView(this.message, {super.key});

  /// The LLM chat message to be displayed.
  final ChatMessage message;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // const Spacer(flex: 1,),
      ChatViewModelClient(
        builder: (context, viewModel, child) {
          final text = message.text;
          final chatStyle = LlmChatViewStyle.resolveFor(
            context,
            viewModel.style,
          );
          final llmStyle = chatStyle.llmMessageStyle!;
          final chatString = viewModel.strings;

          return Flexible(
            flex: llmStyle.flex,
            child: Container(
              constraints: BoxConstraints(
                minWidth: llmStyle.minWidth,
                maxWidth: llmStyle.maxWidth,
              ),
              margin: llmStyle.margin,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      height: 28,
                      width: 28,
                      decoration: llmStyle.iconDecoration,
                      child: Icon(
                        llmStyle.icon,
                        color: llmStyle.iconColor,
                        size: 16,
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HoveringButtons(
                        isUserMessage: false,
                        chatStyle: chatStyle,
                        clipboardText: text,
                        clipboardMessage: chatString.copyToClipboard,
                        child: Container(
                          width: double.infinity,
                          decoration: llmStyle.decoration,
                          margin: const EdgeInsets.only(left: 40),
                          padding: llmStyle.padding,
                          child: text == null
                              ? SizedBox(
                                  width: 32,
                                  child: JumpingDotsProgressIndicator(
                                    fontSize: 24,
                                    color: chatStyle.progressIndicatorColor!,
                                  ),
                                )
                              : AdaptiveCopyText(
                                  clipboardText: text,
                                  chatStyle: chatStyle,
                                  chatStrings: chatString,
                                  child: viewModel.responseBuilder == null
                                      ? MarkdownBody(
                                          data: text,
                                          selectable: false,
                                          styleSheet: llmStyle.markdownStyle,
                                          onTapLink: (_, href, _) {
                                            if (href != null) {
                                              launchUrl(Uri.parse(href));
                                            }
                                          },
                                        )
                                      : viewModel.responseBuilder!(
                                          context,
                                          text,
                                        ),
                                ),
                        ),
                      ),
                      if (message.usage != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 40, top: 4),
                          child: UsageBadge(
                            usage: message.usage!,
                            baseStyle: llmStyle.markdownStyle?.p,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
      const Flexible(flex: 2, child: SizedBox()),
    ],
  );
}

/// A muted one-line token summary rendered under a completed LLM bubble.
///
/// Shows prompt and completion tokens, plus cached/reasoning counts when the
/// provider reported them: `▲ 1,234  ▼ 356 · 800 cached`.
@immutable
class UsageBadge extends StatelessWidget {
  /// Creates a [UsageBadge] for [usage].
  const UsageBadge({required this.usage, this.baseStyle, super.key});

  /// The turn's token usage.
  final UsageDetails usage;

  /// The bubble's body text style the badge derives its muted style from.
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final color = (baseStyle?.color ?? const Color(0xFF888888)).withValues(
      alpha: 0.55,
    );
    return Text(
      usageSummaryText(usage),
      style: (baseStyle ?? const TextStyle()).copyWith(
        fontSize: 11,
        color: color,
      ),
    );
  }
}

/// Formats [usage] as the badge's one-line summary.
String usageSummaryText(UsageDetails usage) {
  final parts = <String>[
    if (usage.inputTokenCount != null)
      '▲ ${formatTokenCount(usage.inputTokenCount!)}',
    if (usage.outputTokenCount != null)
      '▼ ${formatTokenCount(usage.outputTokenCount!)}',
  ];
  final extras = <String>[
    if ((usage.cachedInputTokenCount ?? 0) > 0)
      '${formatTokenCount(usage.cachedInputTokenCount!)} cached',
    if ((usage.reasoningTokenCount ?? 0) > 0)
      '${formatTokenCount(usage.reasoningTokenCount!)} reasoning',
  ];
  return [
    parts.join('  '),
    ...extras,
  ].where((part) => part.isNotEmpty).join(' · ');
}

/// Formats [count] with thousands separators (`12345` → `12,345`).
String formatTokenCount(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

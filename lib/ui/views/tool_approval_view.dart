// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../providers/interface/tool_approval.dart';
import '../strings/llm_chat_view_strings.dart';

/// A card asking the user to approve or deny a pending agent tool call.
///
/// Shown by the chat view between the history and the input whenever the
/// provider reports a [ToolApprovalRequest]. The three actions map to
/// [ToolApprovalDecision]: deny, allow once, or always allow this tool.
@immutable
class ToolApprovalView extends StatelessWidget {
  /// Creates a [ToolApprovalView] for [request].
  const ToolApprovalView({
    required this.request,
    required this.onDecision,
    required this.strings,
    super.key,
  });

  /// The pending tool call to present.
  final ToolApprovalRequest request;

  /// Invoked with the user's decision.
  final ValueChanged<ToolApprovalDecision> onDecision;

  /// The chat view strings used for labels.
  final LlmChatViewStrings strings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final argumentsText = _formatArguments(request.arguments);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.toolApprovalTitle,
                  style: textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            request.toolName,
            style: textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          if (argumentsText != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(
                  argumentsText,
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => onDecision(ToolApprovalDecision.deny),
                child: Text(strings.toolApprovalDeny),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => onDecision(ToolApprovalDecision.alwaysAllow),
                child: Text(strings.toolApprovalAlwaysAllow),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => onDecision(ToolApprovalDecision.allowOnce),
                child: Text(strings.toolApprovalAllowOnce),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _formatArguments(Map<String, Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } on Object {
      return arguments.toString();
    }
  }
}

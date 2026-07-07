// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../../data/usage_store.dart';
import '../views/chat_message_view/llm_message_view.dart' show formatTokenCount;

/// Opens the token-usage sheet for [conversationId].
Future<void> showUsageStats(
  BuildContext context, {
  required UsageStore usage,
  required String conversationId,
  required String currentSessionId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: UsageStatsSheet(
        usage: usage,
        conversationId: conversationId,
        currentSessionId: currentSessionId,
      ),
    ),
  );
}

/// Token totals for the conversation, grouped by model.
///
/// Shows the current session and the whole conversation separately, one row
/// per model with prompt/completion/cached sums and the number of model
/// calls. Raw counts only — pricing varies by provider, so cost math is left
/// to the reader.
class UsageStatsSheet extends StatelessWidget {
  /// Creates a [UsageStatsSheet].
  const UsageStatsSheet({
    required this.usage,
    required this.conversationId,
    required this.currentSessionId,
    super.key,
  });

  /// The durable per-call usage ledger.
  final UsageStore usage;

  /// The conversation whose ledger is shown.
  final String conversationId;

  /// The session in progress, shown as its own section.
  final String currentSessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<ChatUsageRecord>>(
      stream: usage.watchFor(conversationId),
      builder: (context, snapshot) {
        final records = snapshot.data;
        if (records == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (records.isEmpty) {
          return Center(
            child: Text(
              'No token usage recorded yet.',
              style: theme.textTheme.bodyMedium,
            ),
          );
        }
        final session = UsageStore.totalsByModel(
          records,
          sessionId: currentSessionId,
        );
        final conversation = UsageStore.totalsByModel(records);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text('Token usage', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (session.isNotEmpty) ...[
              _SectionHeader('Current session'),
              for (final totals in session.values) _ModelRow(totals),
              const SizedBox(height: 16),
            ],
            _SectionHeader('Whole conversation'),
            for (final totals in conversation.values) _ModelRow(totals),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow(this.totals);

  final ModelUsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    final calls = totals.calls == 1 ? '1 call' : '${totals.calls} calls';
    final counts = [
      '▲ ${formatTokenCount(totals.inputTokens)} in',
      '▼ ${formatTokenCount(totals.outputTokens)} out',
      if (totals.cachedTokens > 0)
        '${formatTokenCount(totals.cachedTokens)} cached',
      if (totals.reasoningTokens > 0)
        '${formatTokenCount(totals.reasoningTokens)} reasoning',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  totals.modelId,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${totals.provider} · $calls', style: muted),
            ],
          ),
          Text(counts, style: muted),
        ],
      ),
    );
  }
}

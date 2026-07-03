import 'dart:convert';

import 'package:agents_llama/agents_llama.dart' show PromptInspector,
    PromptSnapshot;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens a bottom sheet showing the most recent prompt sent to the model.
///
/// Presented as a modal sheet so it works on both the desktop and mobile
/// layouts. The sheet reads [inspector] and rebuilds as new prompts are
/// captured, so it stays current while open.
Future<void> showPromptInspector(
  BuildContext context,
  PromptInspector inspector,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.85,
      child: PromptInspectorPanel(inspector: inspector),
    ),
  );
}

/// The prompt inspector content as a standalone, embeddable widget.
///
/// Rebuilds as [inspector] captures new prompts. Shows the fully rendered
/// wire-format prompt last sent to the model plus the resolved sampling
/// configuration, so it answers "what did the model actually receive" — the
/// first thing to check when a local model gives an unexpected response.
class PromptInspectorPanel extends StatelessWidget {
  /// Creates a panel bound to [inspector].
  const PromptInspectorPanel({required this.inspector, super.key});

  /// The inspector whose latest snapshot is displayed.
  final PromptInspector inspector;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: inspector,
      builder: (context, _) {
        final snapshot = inspector.latest;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: snapshot == null
              ? const _EmptyState()
              : _SnapshotView(snapshot: snapshot),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.data_object_rounded,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('No prompt captured yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Send a message to a local model to see what is sent to it.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotView extends StatelessWidget {
  const _SnapshotView({required this.snapshot});

  final PromptSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text('Sent to model', style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: snapshot.text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Prompt copied')));
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        _SamplingHeader(snapshot: snapshot),
        const SizedBox(height: 12),
        _ContextUsage(snapshot: snapshot),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                snapshot.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows the prompt's data size and how full the model's context window is.
///
/// Token counts are **estimates** (UTF-8 bytes ÷ 4, the same heuristic the
/// harness uses to decide compaction), so they're prefixed with `~`. The
/// estimate reads low when images are attached (their context tokens aren't in
/// the prompt text). The bar turns to the error color past
/// `contextSize − maxTokens`, where the conversation is close enough to full
/// that the harness is about to compact.
class _ContextUsage extends StatelessWidget {
  const _ContextUsage({required this.snapshot});

  final PromptSnapshot snapshot;

  static String _tokens(int count) =>
      count >= 1000 ? '${(count / 1000).toStringAsFixed(1)}k' : '$count';

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = utf8.encode(snapshot.text).length;
    final estTokens = (bytes / 4).round();
    final fraction = (estTokens / snapshot.contextSize).clamp(0.0, 1.0);
    final compactionAt = snapshot.contextSize - snapshot.maxTokens;
    final nearCompaction = estTokens >= compactionAt;
    final percent = (fraction * 100).round();
    final barColor = nearCompaction
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '~${_tokens(estTokens)} / ${_tokens(snapshot.contextSize)} '
                'tokens · $percent% · ~${_size(bytes)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (nearCompaction)
              Text(
                'compaction near',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
      ],
    );
  }
}

class _SamplingHeader extends StatelessWidget {
  const _SamplingHeader({required this.snapshot});

  final PromptSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      'temp ${snapshot.temperature}',
      if (snapshot.topK != null) 'topK ${snapshot.topK}',
      if (snapshot.topP != null) 'topP ${snapshot.topP}',
      if (snapshot.seed != null) 'seed ${snapshot.seed}',
      'maxTokens ${snapshot.maxTokens}',
      if (snapshot.imageCount > 0) 'images ${snapshot.imageCount}',
      if (snapshot.stopSequences.isNotEmpty)
        'stop ${snapshot.stopSequences.join(' ')}',
    ];
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final chip in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              chip,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
      ],
    );
  }
}

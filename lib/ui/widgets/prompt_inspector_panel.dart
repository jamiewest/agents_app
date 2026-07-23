import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/prompt_log.dart';

/// Opens a bottom sheet listing every prompt sent to any model.
///
/// Presented as a modal sheet so it works on both the desktop and mobile
/// layouts. The sheet reads [log] and rebuilds as new prompts are captured, so
/// it stays current while open.
Future<void> showPromptInspector(BuildContext context, PromptLog log) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: PromptInspectorPanel(log: log),
    ),
  );
}

/// A scrollable list of captured prompts — local and cloud alike.
///
/// Each entry shows the model/provider, when it was sent, sampling metadata,
/// and the fully rendered request text (selectable, with a copy button). This
/// answers "what did the model actually receive", the first thing to check when
/// a response looks wrong.
class PromptInspectorPanel extends StatelessWidget {
  /// Creates a panel bound to [log].
  const PromptInspectorPanel({required this.log, super.key});

  /// The prompt log whose entries are displayed.
  final PromptLog log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final entries = log.entries;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Prompts sent to models',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (entries.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(LucideIcons.trash2300, size: 18),
                      label: const Text('Clear'),
                      onPressed: log.clear,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, i) => _EntryCard(
                        entry: entries[i],
                        initiallyExpanded: i == 0,
                      ),
                    ),
            ),
          ],
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
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              LucideIcons.braces300,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('No prompts captured yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Send a message to any model to see exactly what is sent to it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, this.initiallyExpanded = false});

  final PromptLogEntry entry;
  final bool initiallyExpanded;

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = utf8.encode(entry.body).length;
    final estTokens = (bytes / 4).round();
    final tokenTag = estTokens >= 1000
        ? '~${(estTokens / 1000).toStringAsFixed(1)}k tokens'
        : '~$estTokens tokens';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(
            entry.title,
            style: theme.textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${_time(entry.capturedAt)} · $tokenTag',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: <Widget>[
            if (entry.tags.isNotEmpty) ...<Widget>[
              _Tags(tags: entry.tags),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(LucideIcons.copy300, size: 18),
                label: const Text('Copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: entry.body));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Prompt copied')),
                  );
                },
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: SelectableText(
                  entry.body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tags extends StatelessWidget {
  const _Tags({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final tag in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tag,
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

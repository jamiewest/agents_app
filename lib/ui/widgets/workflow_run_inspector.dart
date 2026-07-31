// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/workflows/workflow_run_controller.dart';
import '../app_theme.dart';
import 'workflow_graph_view.dart';

/// Everything shown about the active run: status, graph, stage output,
/// pending requests, final output, and the event log.
class WorkflowRunInspector extends StatelessWidget {
  /// Creates an inspector over [run].
  ///
  /// When [onReplayCheckpoint] is provided, finished runs offer a
  /// "Replay" action on each recorded checkpoint.
  const WorkflowRunInspector({
    required this.run,
    required this.onDiscard,
    this.onReplayCheckpoint,
    super.key,
  });

  /// Replays the run from a checkpoint; null hides the action.
  final void Function(Checkpoint checkpoint)? onReplayCheckpoint;

  final WorkflowRunController run;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stageNodes = [
      for (final layer in run.layers)
        for (final id in layer)
          if (run.nodes[id] case final node?
              when node.text.isNotEmpty || node.reasoning.isNotEmpty)
            node,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _StatusChip(run: run),
            const SizedBox(width: AppSpacing.md),
            Text(
              'Superstep ${run.superSteps}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onDiscard,
              icon: const Icon(LucideIcons.x300, size: 16),
              label: Text(run.isFinished ? 'Clear' : 'Discard'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        WorkflowSectionCard(
          title: run.workflow.name ?? 'Workflow',
          trailing: IconButton(
            tooltip: 'Copy as Mermaid',
            icon: const Icon(LucideIcons.copy300, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: run.toMermaid()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Mermaid definition copied.')),
                );
              }
            },
          ),
          child: WorkflowGraphView(controller: run),
        ),
        for (final request in run.pendingRequests) ...[
          const SizedBox(height: AppSpacing.md),
          _RequestCard(run: run, request: request),
        ],
        for (final node in stageNodes) ...[
          const SizedBox(height: AppSpacing.md),
          WorkflowSectionCard(
            title: switch (node.elapsed) {
              null => node.id,
              final elapsed => '${node.id} · ${_formatDuration(elapsed)}',
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (node.reasoning.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SelectableText(
                      node.reasoning.toString(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                if (node.text.isNotEmpty)
                  SelectableText(
                    node.text.toString(),
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
        ],
        if (run.runError case final error?) ...[
          const SizedBox(height: AppSpacing.md),
          WorkflowSectionCard(
            title: 'Run error',
            child: SelectableText(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        if (run.isFinished && run.finalOutput.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          WorkflowSectionCard(
            title: 'Final output',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final message in run.finalOutput)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SelectableText.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text:
                                '${message.authorName ?? message.role.value}'
                                ':  ',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text: message.text,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (run.checkpointList.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _CheckpointsCard(
            run: run,
            onReplay: run.isFinished ? onReplayCheckpoint : null,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _EventLog(run: run),
      ],
    );
  }

  static String _formatDuration(Duration elapsed) {
    final seconds = elapsed.inMilliseconds / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
    return '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
  }
}

/// The recorded checkpoints, each replayable once the run has finished.
class _CheckpointsCard extends StatelessWidget {
  const _CheckpointsCard({required this.run, required this.onReplay});

  final WorkflowRunController run;
  final void Function(Checkpoint checkpoint)? onReplay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkflowSectionCard(
      title: 'Checkpoints (${run.checkpointList.length})',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The engine snapshots the run after every superstep; replay '
            'rewinds to that point and runs forward again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final checkpoint in run.checkpointList)
            Row(
              children: [
                Icon(
                  LucideIcons.flag300,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'After superstep ${checkpoint.superStep}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (onReplay case final onReplay?)
                  TextButton.icon(
                    onPressed: () => onReplay(checkpoint),
                    icon: const Icon(LucideIcons.rotateCcw300, size: 14),
                    label: const Text('Replay'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A live pill describing the run status.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.run});

  final WorkflowRunController run;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (run.status) {
      RunStatus.notStarted || RunStatus.idle => (
        'Not started',
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
      ),
      RunStatus.running => (
        'Running',
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      RunStatus.pendingRequests => (
        'Waiting on you',
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      RunStatus.ended => (
        run.runError == null ? 'Finished' : 'Failed',
        run.runError == null ? scheme.secondaryContainer : scheme.errorContainer,
        run.runError == null
            ? scheme.onSecondaryContainer
            : scheme.onErrorContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (run.status == RunStatus.running) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: foreground,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Answer box for one human-in-the-loop request.
class _RequestCard extends StatefulWidget {
  const _RequestCard({required this.run, required this.request});

  final WorkflowRunController run;
  final ExternalRequest<dynamic, dynamic> request;

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  final TextEditingController _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _answer.text.trim();
    if (text.isEmpty) return;
    await widget.run.respond(widget.request, text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkflowSectionCard(
      title: 'The workflow needs input — ${widget.request.port.id}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            '${widget.request.request}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _answer,
                  decoration: const InputDecoration(
                    labelText: 'Your answer',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              FilledButton(onPressed: _send, child: const Text('Send')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Collapsible chronological event list for the run.
class _EventLog extends StatelessWidget {
  const _EventLog({required this.run});

  final WorkflowRunController run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkflowSectionCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        title: Text(
          'Event log (${run.log.length})',
          style: theme.textTheme.titleSmall,
        ),
        children: [
          for (final entry in run.log)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Text(
                _timestamp(entry.time),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              title: Text(entry.label, style: theme.textTheme.bodySmall),
              subtitle: entry.detail == null
                  ? null
                  : Text(
                      entry.detail!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  static String _timestamp(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

/// The section container all inspector cards share.
class WorkflowSectionCard extends StatelessWidget {
  /// Creates a section card around [child].
  const WorkflowSectionCard({
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    super.key,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title case final title?)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title, style: theme.textTheme.titleSmall),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

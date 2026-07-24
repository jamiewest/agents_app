// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/agent_center_overview.dart';
import '../../data/agent_run_store.dart';
import 'charts.dart';
import 'dashboard_card.dart';

export 'dashboard_card.dart';

/// Shared dashboard building blocks for the Agent Center Overview and the
/// per-agent detail page, so both render KPIs, charts, and recent runs one
/// way.

/// The 24h/7d/30d/All selector.
class OverviewRangeControl extends StatelessWidget {
  /// Creates an [OverviewRangeControl].
  const OverviewRangeControl({
    required this.range,
    required this.onChanged,
    super.key,
  });

  /// The selected range.
  final OverviewRange range;

  /// Invoked with a new range.
  final ValueChanged<OverviewRange> onChanged;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<OverviewRange>(
        segments: [
          for (final option in OverviewRange.values)
            ButtonSegment(value: option, label: Text(option.label)),
        ],
        selected: {range},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    ),
  );
}

/// A row of KPI cards for an overview snapshot.
class KpiCards extends StatelessWidget {
  /// Creates a [KpiCards].
  const KpiCards({required this.overview, this.fleet = true, super.key});

  /// The snapshot to summarize.
  final AgentCenterOverview overview;

  /// Whether this is a fleet view (the Overview) rather than one agent.
  ///
  /// "Active agents" is a fleet metric — on a per-agent page it is always
  /// one, which says nothing — so the detail page passes false, dropping
  /// that tile and moving the live-run count onto the Runs tile.
  final bool fleet;

  @override
  Widget build(BuildContext context) {
    final rate = overview.successRate;
    final running = overview.runningRuns > 0
        ? '${overview.runningRuns} running now'
        : null;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        if (fleet)
          KpiStatTile(
            label: 'Active agents',
            value: '${overview.activeAgents}',
            sub: running,
          ),
        KpiStatTile(
          label: 'Runs',
          value: '${overview.totalRuns}',
          sub: fleet ? null : running,
        ),
        KpiStatTile(
          label: 'Success rate',
          value: rate == null ? '—' : '${(rate * 100).round()}%',
          // The denominator is stated so the number is not a mystery.
          sub: rate == null
              ? 'No completed runs'
              : '${overview.succeededRuns}/${overview.totalRuns} succeeded',
        ),
        KpiStatTile(
          label: 'Tokens',
          value: compactTokens(overview.totalTokens),
        ),
      ],
    );
  }
}

/// A single KPI: a hero number over a muted label, with optional sub-text.
class KpiStatTile extends StatelessWidget {
  /// Creates a [KpiStatTile].
  const KpiStatTile({
    required this.label,
    required this.value,
    this.sub,
    super.key,
  });

  /// The muted caption.
  final String label;

  /// The hero number.
  final String value;

  /// Optional supporting line.
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: '$label: $value${sub == null ? '' : ', $sub'}',
      child: ExcludeSemantics(
        child: Container(
          width: 168,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(value, style: theme.textTheme.headlineSmall),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(
                  sub!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The runs-over-time and tokens-over-time charts for a snapshot.
class OverviewCharts extends StatelessWidget {
  /// Creates an [OverviewCharts].
  const OverviewCharts({required this.overview, super.key});

  /// The snapshot to plot.
  final AgentCenterOverview overview;

  @override
  Widget build(BuildContext context) {
    final buckets = overview.buckets;
    final runsChart = DashboardCard(
      title: 'Runs',
      child: StackedBarChart(
        data: [
          for (final bucket in buckets)
            BarDatum(
              label: bucketLabel(bucket.start, overview.range),
              good: bucket.succeeded,
              bad: bucket.failed,
            ),
        ],
        semanticSummary:
            '${overview.range.label}: ${overview.totalRuns} runs, '
            '${overview.failedRuns} failed.',
      ),
    );
    final tokensChart = DashboardCard(
      title: 'Tokens',
      child: Sparkline(
        values: [for (final bucket in buckets) bucket.totalTokens.toDouble()],
        semanticSummary:
            '${overview.range.label}: '
            '${compactTokens(overview.totalTokens)} tokens.',
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns when there is room, one when there is not.
        if (constraints.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: runsChart),
              const SizedBox(width: 12),
              Expanded(child: tokensChart),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [runsChart, const SizedBox(height: 12), tokensChart],
        );
      },
    );
  }
}

/// The "not enough history yet" card that stands in for the charts.
class NotEnoughDataCard extends StatelessWidget {
  /// Creates a [NotEnoughDataCard].
  const NotEnoughDataCard({required this.range, super.key});

  /// The range that came up short.
  final OverviewRange range;

  @override
  Widget build(BuildContext context) => DashboardCard(
    title: 'Activity',
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          'Not enough runs in the last ${range.label} to chart yet.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}

/// A recent-runs list, each row linking to its conversation when it has one.
class RecentRunsCard extends StatelessWidget {
  /// Creates a [RecentRunsCard].
  const RecentRunsCard({required this.runs, this.showAgent = true, super.key});

  /// The runs, newest first.
  final List<AgentRunRecord> runs;

  /// Whether to show the agent's name (off on a single-agent detail page).
  final bool showAgent;

  @override
  Widget build(BuildContext context) => DashboardCard(
    title: 'Recent runs',
    child: Column(
      children: [
        for (final run in runs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: RunStatusDot(status: run.status),
            title: Text(showAgent ? run.agentName : runSubtitle(run)),
            subtitle: showAgent ? Text(runSubtitle(run)) : null,
            trailing: run.conversationId == null
                ? null
                : const Icon(LucideIcons.chevronRight300),
            onTap: run.conversationId == null
                ? null
                : () => context.go('/chats/c/${run.conversationId}'),
          ),
      ],
    ),
  );
}

/// A colored dot for a run's outcome.
class RunStatusDot extends StatelessWidget {
  /// Creates a [RunStatusDot].
  const RunStatusDot({required this.status, super.key});

  /// The run's status.
  final AgentRunStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      AgentRunStatus.succeeded => scheme.primary,
      AgentRunStatus.failed => scheme.error,
      AgentRunStatus.running => scheme.tertiary,
      AgentRunStatus.interrupted => scheme.outline,
    };
    return Semantics(
      label: status.name,
      child: Icon(Icons.circle, size: 12, color: color),
    );
  }
}

/// A one-line description of a run: its origin and model.
String runSubtitle(AgentRunRecord run) {
  final origin = switch (run.origin) {
    AgentRunOrigin.chat => 'Chat',
    AgentRunOrigin.scheduledTask => 'Task',
    AgentRunOrigin.hostedRequest => 'Hosted',
  };
  final model = run.modelName;
  return model == null ? origin : '$origin · $model';
}

/// A short bucket axis label: hour for a 24h range, day otherwise.
String bucketLabel(DateTime start, OverviewRange range) =>
    range == OverviewRange.day
    ? '${start.hour.toString().padLeft(2, '0')}:00'
    : '${start.month}/${start.day}';

/// Formats a token count compactly: 1.2k, 3.4M.
String compactTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${(tokens / 1000).toStringAsFixed(1)}k';
  return '${(tokens / 1000000).toStringAsFixed(1)}M';
}

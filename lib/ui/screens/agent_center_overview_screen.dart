// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/agent_center_overview.dart';
import '../../data/agent_run_store.dart';
import '../../data/usage_store.dart';
import '../widgets/agent_dashboard.dart';

/// The Agent Center's operational dashboard.
///
/// A sibling of the catalogs, reachable from the shared [AgentCenterNav].
/// Leads with KPI cards and a configuration-issues list — the low-data view
/// is the common one, because operational history only begins after this
/// feature ships. Time-series charts appear once there is enough completed
/// work to be worth plotting.
class AgentCenterOverviewBody extends StatefulWidget {
  /// Creates an [AgentCenterOverviewBody].
  const AgentCenterOverviewBody({
    required this.services,
    this.now,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// Injectable clock for deterministic tests. Defaults to [DateTime.now].
  final DateTime Function()? now;

  @override
  State<AgentCenterOverviewBody> createState() =>
      _AgentCenterOverviewBodyState();
}

class _AgentCenterOverviewBodyState extends State<AgentCenterOverviewBody> {
  late final AgentRunTelemetryStore _runs;
  late final UsageStore _usage;
  late final ConfiguredAgentsManager _manager;

  StreamSubscription<List<AgentRunRecord>>? _runsSub;
  StreamSubscription<void>? _configSub;

  OverviewRange _range = OverviewRange.week;
  AgentCenterOverview? _overview;
  List<_ConfigurationIssue> _issues = const [];
  bool _loading = true;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _runs = widget.services.getRequiredService<AgentRunTelemetryStore>();
    _usage = widget.services.getRequiredService<UsageStore>();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    // The dashboard rebuilds as runs land and as configuration changes; a
    // finished run and a newly-broken agent both belong on it live.
    _runsSub = _runs.watch().listen((_) => unawaited(_reload()));
    _configSub = _manager.configurationChanges.listen(
      (_) => unawaited(_reload()),
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_runsSub?.cancel());
    unawaited(_configSub?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final now = _now;
    final runs = await _runs.list();
    final tokens = await _usage.tokenPointsSince(_range.since(now));
    final issues = await _loadIssues();
    if (!mounted) return;
    setState(() {
      _overview = AgentCenterOverview.from(
        range: _range,
        now: now,
        runs: runs,
        tokenPoints: tokens,
      );
      _issues = issues;
      _loading = false;
    });
  }

  /// Finds agents that cannot run: their model or source is gone, or a
  /// key-requiring source has no key. Configuration only — no network check,
  /// so nothing here implies a provider is reachable.
  Future<List<_ConfigurationIssue>> _loadIssues() async {
    final agents = await _manager.agents.listAgents();
    final models = await _manager.sources.listModels();
    final sources = await _manager.sources.listSources();
    final modelsById = {for (final m in models) m.id: m};
    final sourcesById = {for (final s in sources) s.id: s};

    final issues = <_ConfigurationIssue>[];
    for (final agent in agents) {
      final model = modelsById[agent.modelId];
      if (model == null) {
        issues.add(_ConfigurationIssue(agent.id, agent.name, 'No model'));
        continue;
      }
      final source = sourcesById[model.sourceId];
      if (source == null) {
        issues.add(_ConfigurationIssue(agent.id, agent.name, 'No source'));
        continue;
      }
      if (source.providerType.requiresApiKey &&
          !await _manager.hasSourceApiKey(source.id)) {
        issues.add(
          _ConfigurationIssue(agent.id, agent.name, 'Missing API key'),
        );
      }
    }
    return issues;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(child: _content(context)),
    );
  }

  Widget _content(BuildContext context) {
    final overview = _overview!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1000),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OverviewRangeControl(
              range: _range,
              onChanged: (range) {
                setState(() => _range = range);
                unawaited(_reload());
              },
            ),
            const SizedBox(height: 16),
            KpiCards(overview: overview),
            if (_issues.isNotEmpty) ...[
              const SizedBox(height: 24),
              _IssuesPanel(issues: _issues),
            ],
            if (overview.hasTimeSeries) ...[
              const SizedBox(height: 24),
              OverviewCharts(overview: overview),
            ] else ...[
              const SizedBox(height: 24),
              NotEnoughDataCard(range: _range),
            ],
            if (overview.workload.isNotEmpty) ...[
              const SizedBox(height: 24),
              _WorkloadPanel(overview: overview),
            ],
            if (overview.recentRuns.isNotEmpty) ...[
              const SizedBox(height: 24),
              RecentRunsCard(runs: overview.recentRuns),
            ],
          ],
        ),
      ),
    );
  }
}

/// An agent that cannot currently run, and why.
class _ConfigurationIssue {
  const _ConfigurationIssue(this.agentId, this.agentName, this.reason);

  final String agentId;
  final String agentName;
  final String reason;
}

/// Per-agent run counts as labelled proportion bars.
class _WorkloadPanel extends StatelessWidget {
  const _WorkloadPanel({required this.overview});

  final AgentCenterOverview overview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = overview.workload.fold<int>(
      0,
      (m, w) => w.runs > m ? w.runs : m,
    );
    return DashboardCard(
      title: 'Workload by agent',
      child: Column(
        children: [
          for (final agent in overview.workload)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Semantics(
                label: '${agent.agentName}: ${agent.runs} runs',
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 120,
                        child: Text(
                          agent.agentName,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: max == 0 ? 0 : agent.runs / max,
                            minHeight: 8,
                            backgroundColor: scheme.surfaceContainerHighest,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${agent.runs}',
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Agents that cannot run, each linking to its editor.
class _IssuesPanel extends StatelessWidget {
  const _IssuesPanel({required this.issues});

  final List<_ConfigurationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DashboardCard(
      title: 'Needs setup',
      child: Column(
        children: [
          for (final issue in issues)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                LucideIcons.triangleAlert300,
                color: scheme.error,
                size: 20,
              ),
              title: Text(issue.agentName),
              subtitle: Text(issue.reason),
              trailing: const Icon(LucideIcons.chevronRight300),
              onTap: () => context.go('/settings/agents/edit/${issue.agentId}'),
            ),
        ],
      ),
    );
  }
}

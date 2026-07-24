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

/// A read-only view of one saved agent: its configuration, tool access,
/// delegations, and its own operational history. Edit is an action here, not
/// the landing — tapping an agent opens this page, and its Edit button opens
/// the form.
class AgentDetailScreen extends StatefulWidget {
  /// Creates an [AgentDetailScreen].
  const AgentDetailScreen({
    required this.services,
    required this.agentId,
    this.now,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The agent to show.
  final String agentId;

  /// Injectable clock for deterministic tests.
  final DateTime Function()? now;

  @override
  State<AgentDetailScreen> createState() => _AgentDetailScreenState();
}

class _AgentDetailScreenState extends State<AgentDetailScreen> {
  late final AgentRunTelemetryStore _runs;
  late final UsageStore _usage;
  late final ConfiguredAgentsManager _manager;

  StreamSubscription<List<AgentRunRecord>>? _runsSub;
  StreamSubscription<void>? _configSub;

  OverviewRange _range = OverviewRange.week;
  SavedAgentConfig? _agent;
  ModelConfig? _model;
  ModelSourceConfig? _source;
  AgentCenterOverview? _overview;
  Map<String, String> _agentNames = const {};
  bool _loading = true;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _runs = widget.services.getRequiredService<AgentRunTelemetryStore>();
    _usage = widget.services.getRequiredService<UsageStore>();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
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
    final allAgents = await _manager.agents.listAgents();
    final names = {for (final a in allAgents) a.id: a.name};
    final agent = await _manager.agents.getAgent(widget.agentId);
    final model = agent == null
        ? null
        : await _manager.sources.getModel(agent.modelId);
    final source = model == null
        ? null
        : await _manager.sources.getSource(model.sourceId);
    // Only this agent's runs and tokens — a per-agent chart must not sum in
    // everyone else's work.
    final runs = await _runs.list(agentId: widget.agentId);
    final tokens = await _usage.tokenPointsSince(
      _range.since(now),
      agentId: widget.agentId,
    );
    if (!mounted) return;
    setState(() {
      _agent = agent;
      _model = model;
      _source = source;
      _agentNames = names;
      _overview = AgentCenterOverview.from(
        range: _range,
        now: now,
        runs: runs,
        tokenPoints: tokens,
      );
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    return Scaffold(
      appBar: AppBar(
        title: Text(agent?.name ?? 'Agent'),
        actions: [
          if (agent != null)
            TextButton.icon(
              onPressed: () => context.go('/settings/agents/edit/${agent.id}'),
              icon: const Icon(LucideIcons.pencil300, size: 18),
              label: const Text('Edit'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : agent == null
          ? _deleted(context)
          : _content(context, agent),
    );
  }

  /// The agent was deleted (or the id is stale); the run history it left
  /// behind still carries its snapshotted name elsewhere.
  Widget _deleted(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('This agent no longer exists.'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.go('/settings/agents'),
            child: const Text('Back to agents'),
          ),
        ],
      ),
    ),
  );

  Widget _content(BuildContext context, SavedAgentConfig agent) {
    final overview = _overview!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _IdentityCard(agent: agent, model: _model, source: _source),
                const SizedBox(height: 16),
                OverviewRangeControl(
                  range: _range,
                  onChanged: (range) {
                    setState(() => _range = range);
                    unawaited(_reload());
                  },
                ),
                const SizedBox(height: 16),
                KpiCards(overview: overview, fleet: false),
                const SizedBox(height: 24),
                if (overview.hasTimeSeries)
                  OverviewCharts(overview: overview)
                else
                  NotEnoughDataCard(range: _range),
                if (agent.instructions.trim().isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _InstructionsCard(instructions: agent.instructions.trim()),
                ],
                const SizedBox(height: 24),
                _AccessCard(access: agent.access ?? const AgentAccessConfig()),
                if (agent.delegations.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _DelegationsCard(
                    delegations: agent.delegations,
                    nameFor: _agentNameFor,
                  ),
                ],
                if (overview.recentRuns.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  RecentRunsCard(runs: overview.recentRuns, showAgent: false),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A delegate's display name, or its id when it has been deleted.
  String _agentNameFor(String id) => _agentNames[id] ?? id;
}

/// Model and source, with a broken-configuration warning.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.agent,
    required this.model,
    required this.source,
  });

  final SavedAgentConfig agent;
  final ModelConfig? model;
  final ModelSourceConfig? source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = model == null
        ? 'This agent has no model — it cannot run.'
        : source == null
        ? 'This agent\'s source is missing — it cannot run.'
        : null;
    return DashboardCard(
      title: 'Configuration',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (agent.description.trim().isNotEmpty) ...[
            Text(agent.description.trim()),
            const SizedBox(height: 12),
          ],
          _Field(label: 'Model', value: model?.label ?? 'Missing'),
          _Field(label: 'Source', value: source?.displayName ?? 'Missing'),
          if (problem != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  LucideIcons.triangleAlert300,
                  size: 16,
                  color: scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(problem, style: TextStyle(color: scheme.error)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// The agent's system instructions, verbatim.
class _InstructionsCard extends StatelessWidget {
  const _InstructionsCard({required this.instructions});

  final String instructions;

  @override
  Widget build(BuildContext context) =>
      DashboardCard(title: 'Instructions', child: Text(instructions));
}

/// The enabled tools, as chips. Only the ones that are on are shown — an
/// exhaustive on/off grid would be noise on a read-only page.
class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.access});

  final AgentAccessConfig access;

  @override
  Widget build(BuildContext context) {
    final enabled = <String>[
      if (access.enableFileMemory) 'File memory',
      if (access.enableFileAccess) 'File access',
      if (access.enableFileWriteTools) 'File writes',
      if (access.enableWebSearch) 'Web search',
      if (access.enableShell) 'Shell',
      if (access.enableTodoList) 'Todo list',
      if (access.enableAgentMode) 'Agent mode',
      if (access.enableSkills) 'Skills',
      if (access.enableTemporal) 'Time',
      if (access.enableConnectivity) 'Connectivity',
      if (access.enableAppInfo) 'App info',
      if (access.enableDeviceInfo) 'Device info',
      if (access.enableLocation) 'Location',
      if (access.enableNetworkInfo) 'Network info',
      if (access.enableWakeLock) 'Wake lock',
    ];
    return DashboardCard(
      title: 'Tool access',
      child: enabled.isEmpty
          ? Text(
              'No tools enabled.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final tool in enabled) Chip(label: Text(tool))],
            ),
    );
  }
}

/// The agents this agent can delegate to.
class _DelegationsCard extends StatelessWidget {
  const _DelegationsCard({required this.delegations, required this.nameFor});

  final List<AgentDelegationConfig> delegations;
  final String Function(String id) nameFor;

  @override
  Widget build(BuildContext context) => DashboardCard(
    title: 'Delegates',
    child: Column(
      children: [
        for (final delegation in delegations)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.workflow300, size: 20),
            title: Text(nameFor(delegation.agentId)),
            subtitle: delegation.instructions.trim().isEmpty
                ? null
                : Text(delegation.instructions.trim()),
            trailing: const Icon(LucideIcons.chevronRight300),
            // Push, not go: a delegate opens on top so back returns to the
            // agent that delegates to it rather than collapsing to the list.
            onTap: () =>
                context.push('/settings/agents/view/${delegation.agentId}'),
          ),
      ],
    ),
  );
}

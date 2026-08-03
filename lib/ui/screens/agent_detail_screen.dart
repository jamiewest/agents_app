// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:qr_flutter/qr_flutter.dart';
import 'package:tor_flutter/tor_flutter.dart';

import '../../features/inventory/inventory_access_settings.dart';
import '../../features/tor/tor_sharing_settings.dart';
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
    this.onEdit,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The agent to show.
  final String agentId;

  /// Injectable clock for deterministic tests.
  final DateTime Function()? now;

  /// Handles Edit with the agent's id instead of routing to the editor.
  ///
  /// Supplied by the two-pane catalog, which swaps this pane for the form
  /// rather than pushing a page over a layout that already has room for it.
  final ValueChanged<String>? onEdit;

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
              onPressed: () => widget.onEdit == null
                  ? context.go('/settings/agents/edit/${agent.id}')
                  : widget.onEdit!(agent.id),
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
                _AccessCard(
                  access: agent.access ?? const AgentAccessConfig(),
                  // Inventory access is app-local, not part of the agent's
                  // access record; absent settings (web) read as disabled.
                  inventoryEnabled:
                      widget.services
                          .getService<InventoryAccessSettings>()
                          ?.enabledFor(agent.id) ??
                      false,
                ),
                if (widget.services.getService<NetworkSharingSettings>()
                    case final sharing? when sharing.isSupported) ...[
                  const SizedBox(height: 24),
                  _SharingCard(
                    settings: sharing,
                    tor: widget.services.getService<TorSharingSettings>(),
                    agentId: agent.id,
                  ),
                ],
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
  const _AccessCard({required this.access, required this.inventoryEnabled});

  final AgentAccessConfig access;

  /// The app-local inventory-tools grant (see `InventoryAccessSettings`).
  final bool inventoryEnabled;

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
      if (access.enablePushover) 'Pushover',
      if (inventoryEnabled) 'Inventory',
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

/// Offers this agent to paired devices on the local network.
///
/// Sharing lives on the agent rather than on a screen of its own: it is a
/// property of this agent, and the decision is made while looking at what it
/// can do. The pairing code sits here too — it is the only thing a peer needs
/// once something is being served, and the host it pairs with exists only
/// because an agent on some page like this one was switched on.
class _SharingCard extends StatelessWidget {
  const _SharingCard({required this.settings, required this.agentId, this.tor});

  final NetworkSharingSettings settings;

  /// Tor sharing, when the app registered it. Absent on platforms that
  /// cannot host.
  final TorSharingSettings? tor;

  final String agentId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, tor]),
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final shared = settings.isShared(agentId);
      return DashboardCard(
        title: 'Network sharing',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: shared,
              title: const Text('Share on the network'),
              subtitle: Text(switch ((
                shared && settings.isRunning,
                settings.loopbackOnly,
              )) {
                // Bound to loopback for the onion forward, so the port is
                // real but nothing on this network can reach it.
                (true, true) =>
                  'Reachable over Tor only — not served on this network',
                (true, false) =>
                  'Paired devices can use this agent — serving on port '
                      '${settings.port}',
                _ =>
                  'Let paired devices on this network use this agent as '
                      'their own teammate (A2A)',
              }),
              onChanged: settings.busy
                  ? null
                  : (value) => unawaited(settings.setShared(agentId, value)),
            ),
            Text(
              'Keep the app open while sharing. Traffic is unencrypted local '
              'HTTP — share only on networks you trust.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (settings.error case final error?) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: scheme.error)),
            ],
            if (settings.isRunning) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => unawaited(_showPairingCode(context)),
                icon: const Icon(LucideIcons.qrCode300),
                label: const Text('Show pairing code'),
              ),
            ],
            if (tor case final tor? when tor.isSupported && shared) ...[
              const Divider(height: 32),
              _TorSharingSection(
                tor: tor,
                onShowPairingCode: () =>
                    unawaited(_showPairingCode(context, tor: tor)),
              ),
            ],
          ],
        ),
      );
    },
  );

  Future<void> _showPairingCode(
    BuildContext context, {
    TorSharingSettings? tor,
  }) async {
    final PairingPayload offer;
    try {
      offer = await (tor == null
          ? settings.createPairingOffer()
          : tor.createPairingOffer());
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pairing code'),
        // An explicit width is load-bearing, not styling. Without it the
        // dialog measures its content's intrinsic width, and QrImageView
        // renders through a LayoutBuilder, which cannot answer an intrinsic
        // query — it throws during layout, so the barrier appears with
        // nothing on it and the app looks wedged.
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    // QR codes need a white quiet zone for scanner contrast
                    // in both themes; not a theme role.
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: QrImageView(data: offer.encode(), size: 220),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Scan this on the other device, or paste the code below '
                  'into its "Add network agent" screen. Single-use; expires '
                  'in two minutes.',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  offer.encode(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
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

/// Offers the same shared agents over Tor, so peers do not have to be on this
/// network.
///
/// Sits under network sharing rather than beside it because it is a second
/// route to the same host: the agents on offer are the ones already switched
/// on above.
class _TorSharingSection extends StatelessWidget {
  const _TorSharingSection({
    required this.tor,
    required this.onShowPairingCode,
  });

  final TorSharingSettings tor;
  final VoidCallback onShowPairingCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: tor.enabled,
          title: const Text('Share over Tor'),
          subtitle: Text(_subtitleFor(tor)),
          // Disabled once the key is lost rather than left to bounce back:
          // every attempt fails on the same missing key, and a switch that
          // refuses without saying why is what left people stuck here.
          onChanged: tor.busy || tor.isIdentityUnrecoverable
              ? null
              : (value) => unawaited(tor.setEnabled(value)),
        ),
        if (tor.address case final address?) ...[
          const SizedBox(height: 4),
          _OnionAddress(address: address, dimmed: !tor.isPublished),
        ],
        const SizedBox(height: 8),
        Text(
          'Your address stays the same, so a peer only has to pair once. '
          'Keep the app open — agents are reachable only while it runs.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (tor.error case final error?) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: scheme.error)),
        ],
        if (tor.isIdentityUnrecoverable) ...[
          const SizedBox(height: 8),
          Text(
            'Sharing over Tor cannot start again until this device gets a new '
            'identity. That means a new address, so everyone already paired '
            'over Tor has to pair again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            // The escape hatch. Without it the only fix is editing storage by
            // hand outside the app.
            onPressed: tor.busy
                ? null
                : () => unawaited(_confirmReset(context)),
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(LucideIcons.trash2300, size: 18),
            label: const Text('Reset Tor identity'),
          ),
        ],
        if (tor.isPublished) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onShowPairingCode,
            icon: const Icon(LucideIcons.qrCode300),
            label: const Text('Show Tor pairing code'),
          ),
        ],
      ],
    );
  }

  /// Asks before throwing away the identity, because the cost lands on the
  /// user's peers rather than on this device: a mis-tap silently breaks every
  /// pairing they have, and nothing can undo it.
  Future<void> _confirmReset(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Tor identity?'),
        content: const Text(
          'This device gets a brand new onion address. The old one stops '
          'working for good, so every device paired over Tor has to be '
          'paired again with a new code.\n\n'
          'The current address cannot be recovered — resetting is the only '
          'way to share over Tor from this device again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset identity'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await tor.resetIdentity();
  }

  static String _subtitleFor(TorSharingSettings tor) {
    // Takes precedence over the lifecycle: Tor itself may be perfectly fine,
    // and reporting that would leave the switch looking merely off.
    if (tor.isIdentityUnrecoverable) {
      return 'Unavailable — this device lost its Tor identity';
    }
    return switch (tor.status) {
      TorBootstrapping(:final progress) when tor.enabled =>
        'Connecting to Tor… ${(progress * 100).round()}%',
      TorReady() when tor.isPublished =>
        'Reachable from anywhere at the address below',
      TorFailed() => 'Tor is not running',
      _ => 'Let peers use this agent without being on your network',
    };
  }
}

/// The onion address, with a copy action.
///
/// Shown even while unpublished — it is the identity the user has already
/// handed out, and blanking it would suggest it had changed.
class _OnionAddress extends StatelessWidget {
  const _OnionAddress({required this.address, required this.dimmed});

  final String address;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              address,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: dimmed ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy address',
            icon: const Icon(LucideIcons.copy300, size: 18),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: address)));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Address copied')));
            },
          ),
        ],
      ),
    );
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tor_flutter/tor_flutter.dart';

import '../../data/app_reset.dart';
import '../../data/theme_settings.dart';
import '../dialogs/pushover_credentials.dart';
import '../widgets/app_sliver_header.dart';
import '../../features/tor/tor_settings.dart';
import '../widgets/page_body.dart';
import '../widgets/settings_page.dart';

/// The Settings destination: entry points into configuration surfaces.
class SettingsHomeScreen extends StatelessWidget {
  /// Creates a [SettingsHomeScreen].
  const SettingsHomeScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        const AppSliverHeader(title: 'Settings'),
        SliverToBoxAdapter(
          child: PageBody(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Agent Center leads: managing agents is the reason people
                // open Settings, so it gets a card rather than a row buried
                // among appearance and diagnostics.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: _AgentCenterCard(
                    manager: services
                        .getRequiredService<ConfiguredAgentsManager>(),
                  ),
                ),
                const SettingsGroupLabel('You'),
                _ProfileTile(
                  settings: services.getRequiredService<UserProfileSettings>(),
                ),
                const SettingsGroupLabel('App'),
                _AppearanceTile(
                  settings: services.getRequiredService<ThemeSettings>(),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.receiptText300),
                  title: const Text('Logs & diagnostics'),
                  subtitle: const Text(
                    'Live app logs, prompts sent to models, and log levels',
                  ),
                  trailing: const Icon(LucideIcons.chevronRight300),
                  onTap: () => context.go('/settings/logging'),
                ),
                const SettingsGroupLabel('Agent tools'),
                _PushoverTile(
                  settings: services.getRequiredService<PushoverSettings>(),
                ),
                // Absent on web, where the local web tools are unsupported
                // and the service is never registered.
                if (services.getService<WebSearchSettings>()
                    case final webSearch?)
                  _WebSearchTile(settings: webSearch),
                const SettingsGroupLabel('Connections'),
                // Absent where there is no Tor backend, so the row never
                // offers something the device cannot do. Pairing is listed
                // regardless: consuming someone else's code is a client
                // action, and works over the local network without Tor.
                if (services.getService<TorSettings>() case final tor?)
                  _TorTile(settings: tor),
                const _PairDeviceTile(),
                const Divider(height: 32),
                ListTile(
                  leading: Icon(
                    LucideIcons.rotateCcw300,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Reset app data',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  subtitle: const Text(
                    'Erase all agents, API keys, conversations, and '
                    'downloaded models, then start fresh',
                  ),
                  onTap: () => _confirmReset(context),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset app data?'),
        content: const Text(
          'This permanently erases all model sources, API keys, models, '
          'saved agents, conversations, channels, tasks, agent memory, and '
          'downloaded local models.\n\n'
          'The app closes when the reset finishes; launch it again to '
          'start fresh.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Erase everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await resetAppData(services);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reset failed: $error')));
      return;
    }
    restartApp();
  }
}

/// The Settings row for the Pushover notification tools.
///
/// Live: the subtitle flips between "not configured" and "agents can send
/// notifications" the moment credentials are saved or cleared.
class _PushoverTile extends StatelessWidget {
  const _PushoverTile({required this.settings});

  final PushoverSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.bellRing300),
      title: const Text('Pushover notifications'),
      subtitle: Text(
        settings.isConfigured
            ? 'Configured — enable per agent under the agent\'s tools'
            : 'Let agents send push notifications to your devices',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => _edit(context),
    ),
  );

  Future<void> _edit(BuildContext context) =>
      showPushoverCredentialsDialog(context, settings);
}

/// The Settings row for the local web-search tools.
///
/// Live: the subtitle flips between the setup hint and "configured" the
/// moment a key is saved or cleared.
class _WebSearchTile extends StatelessWidget {
  const _WebSearchTile({required this.settings});

  final WebSearchSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.globe300),
      title: const Text('Web search'),
      subtitle: Text(
        settings.isConfigured
            ? 'Configured — agents search through '
                  '"${settings.selectedClient?.name}" and read pages on '
                  'this device'
            : 'Let agents search the web through any search URL you choose',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/web-search'),
    ),
  );
}

/// The Settings row for pairing with an agent shared by another device.
///
/// The pairing screen already existed but nothing in Settings led to it — the
/// only way in was a card buried in the add-agent wizard, which is not where
/// anyone holding a pairing code thinks to look.
class _PairDeviceTile extends StatelessWidget {
  const _PairDeviceTile();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.qrCode300),
    title: const Text('Pair with a device'),
    subtitle: const Text(
      'Use an agent shared by another device. It joins your agent list.',
    ),
    trailing: const Icon(LucideIcons.chevronRight300),
    onTap: () => context.go('/settings/network/pair'),
  );
}

/// The Settings row for the app-wide Tor switch.
///
/// Live: the subtitle reports bootstrap progress, because a cold start takes
/// tens of seconds and a row that just read "on" would look stuck.
class _TorTile extends StatelessWidget {
  const _TorTile({required this.settings});

  final TorSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.shield300),
      title: const Text('Tor'),
      subtitle: Text(switch (settings.status) {
        TorBootstrapping(:final progress) when settings.enabled =>
          'Connecting… ${(progress * 100).round()}%',
        TorReady() when settings.enabled =>
          'Connected — agents shared at a .onion address are reachable',
        TorFailed() when settings.enabled => 'Could not connect',
        _ => 'Reach agents shared at a .onion address from anywhere',
      }),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/tor'),
    ),
  );
}

/// The Settings row for the user's own profile.
///
/// Live: the subtitle names the person once one is set, so it is obvious at
/// a glance whether agents are being told anything about you.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.settings});

  final UserProfileSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.userRound300),
      title: const Text('Profile'),
      subtitle: Text(switch ((settings.name, settings.bio)) {
        ('', '') => 'Tell agents your name and what you work on',
        ('', _) => 'Agents know what you work on',
        (final name, '') => 'Agents call you $name',
        (final name, _) => 'Agents call you $name and know what you work on',
      }),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/profile'),
    ),
  );
}

/// The Settings row for theme mode and accent colour.
///
/// Live: the subtitle names the current mode and palette, which is what the
/// block of controls that used to sit here communicated at a glance.
class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile({required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.palette300),
      title: const Text('Appearance'),
      subtitle: Text(
        '${switch (settings.mode) {
          ThemeMode.system => 'System',
          ThemeMode.light => 'Light',
          ThemeMode.dark => 'Dark',
        }} \u00b7 ${settings.seed.label}',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/appearance'),
    ),
  );
}

/// The Settings entry point into the Agent Center.
///
/// Summarizes state rather than describing the destination: how many agents
/// exist, and whether anything needs setup before it can run. A count of
/// zero, or an agent whose model or source has gone missing, is the reason
/// most people open this screen at all.
class _AgentCenterCard extends StatelessWidget {
  const _AgentCenterCard({required this.manager});

  final ConfiguredAgentsManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/settings/agents'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(LucideIcons.bot300, size: 28, color: scheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Agent Center',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    _AgentCenterSummary(manager: manager),
                  ],
                ),
              ),
              const Icon(LucideIcons.chevronRight300),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of live configuration state under the Agent Center title.
class _AgentCenterSummary extends StatefulWidget {
  const _AgentCenterSummary({required this.manager});

  final ConfiguredAgentsManager manager;

  @override
  State<_AgentCenterSummary> createState() => _AgentCenterSummaryState();
}

class _AgentCenterSummaryState extends State<_AgentCenterSummary> {
  late Future<({int agents, int needsSetup})> _summary;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _summary = _load();
    _changes = widget.manager.configurationChanges.listen((_) {
      if (!mounted) return;
      // Start the reload outside setState: an arrow body would hand the
      // framework a Future as the callback's return value.
      final reloaded = _load();
      setState(() {
        _summary = reloaded;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Counts saved agents, and those whose model or source no longer
  /// resolves. Configuration only — this makes no network call, so it never
  /// implies a provider is reachable.
  Future<({int agents, int needsSetup})> _load() async {
    final agents = await widget.manager.agents.listAgents();
    final models = await widget.manager.sources.listModels();
    final sources = await widget.manager.sources.listSources();
    final modelsById = {for (final model in models) model.id: model};
    final sourceIds = {for (final source in sources) source.id};
    var needsSetup = 0;
    for (final agent in agents) {
      final model = modelsById[agent.modelId];
      if (model == null || !sourceIds.contains(model.sourceId)) needsSetup++;
    }
    return (agents: agents.length, needsSetup: needsSetup);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<({int agents, int needsSetup})>(
      future: _summary,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return Text(
            'Agents, models, and sources',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          );
        }
        final agents = data.agents == 1 ? '1 agent' : '${data.agents} agents';
        final needsSetup = data.needsSetup;
        return Text(
          needsSetup == 0
              ? '$agents · models and sources'
              : '$agents · $needsSetup need setup',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: needsSetup == 0 ? scheme.onSurfaceVariant : scheme.error,
          ),
        );
      },
    );
  }
}

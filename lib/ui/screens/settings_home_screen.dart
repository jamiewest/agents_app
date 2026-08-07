// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:llama_cpp_flutter/orchestration.dart' as llama;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tor_flutter/tor_flutter.dart';

import '../../data/theme_settings.dart';
import '../../features/local_models/local_model_disk.dart';
import '../widgets/app_sliver_header.dart';
import '../../features/tor/tor_settings.dart';
import '../app_theme.dart';
import '../widgets/page_body.dart';
import '../widgets/settings_page.dart';
import '../widgets/settings_shell.dart';
import 'storage_settings_screen.dart' show formatBytes;

/// The Settings destination: entry points into configuration surfaces.
///
/// In the shell's two-pane layout the sidebar already shows this list, so
/// the route renders a pick-a-section placeholder instead — the same shape
/// the Chats branch shows beside its sidebar before a conversation opens.
class SettingsHomeScreen extends StatelessWidget {
  /// Creates a [SettingsHomeScreen].
  const SettingsHomeScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    if (SettingsScope.twoPaneOf(context)) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.settings300,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Select a settings section.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const AppSliverHeader(title: 'Settings'),
          SliverToBoxAdapter(
            child: PageBody(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Agents lead: managing agents and what they can do is the
                  // reason people open Settings, so everything agent-shaped
                  // sits in one section at the top.
                  const SettingsGroupLabel('Agents'),
                  _AgentCenterTile(
                    manager: services
                        .getRequiredService<ConfiguredAgentsManager>(),
                  ),
                  if (services.getService<SkillStore>() case final skills?)
                    _SkillsTile(skills: skills),
                  _MemoryTile(services: services),
                  // Absent on web, where the local web tools are unsupported
                  // and the service is never registered.
                  if (services.getService<WebSearchSettings>()
                      case final webSearch?)
                    _WebSearchTile(settings: webSearch),
                  if (services.getService<PushoverSettings>()
                      case final pushover?)
                    _NotificationsTile(settings: pushover),
                  const SettingsGroupLabel('You'),
                  _ProfileTile(
                    settings: services
                        .getRequiredService<UserProfileSettings>(),
                  ),
                  _AppearanceTile(
                    settings: services.getRequiredService<ThemeSettings>(),
                  ),
                  const SettingsGroupLabel('App'),
                  ListTile(
                    leading: const Icon(LucideIcons.slidersHorizontal300),
                    title: const Text('General'),
                    subtitle: const Text(
                      'Onboarding, chat behavior, and resetting app data',
                    ),
                    trailing: const Icon(LucideIcons.chevronRight300),
                    onTap: () => context.go('/settings/general'),
                  ),
                  _StorageTile(services: services),
                  const _HardwareTile(),
                  _AboutTile(appInfo: services.getService<AppInfo>()),
                  const SettingsGroupLabel('Connections'),
                  // Absent where there is no Tor backend, so the row never
                  // offers something the device cannot do. Pairing is listed
                  // regardless: consuming someone else's code is a client
                  // action, and works over the local network without Tor.
                  if (services.getService<TorSettings>() case final tor?)
                    _TorTile(settings: tor),
                  const _PairDeviceTile(),
                  const _PairedDevicesTile(),
                  const SettingsGroupLabel('Diagnostics'),
                  ListTile(
                    leading: const Icon(LucideIcons.receiptText300),
                    title: const Text('Logs & diagnostics'),
                    subtitle: const Text(
                      'Live app logs, prompts sent to models, and log levels',
                    ),
                    trailing: const Icon(LucideIcons.chevronRight300),
                    onTap: () => context.go('/settings/logging'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Settings row into the Storage page.
///
/// The subtitle totals what local models occupy once measured, so the
/// number that decides "do I need to clean up?" is visible from the list.
class _StorageTile extends StatefulWidget {
  const _StorageTile({required this.services});

  final ServiceProvider services;

  @override
  State<_StorageTile> createState() => _StorageTileState();
}

class _StorageTileState extends State<_StorageTile> {
  String? _summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final models = await manager.sources.listModels();
    final sources = await manager.sources.listSources();
    final localSourceIds = {
      for (final source in sources)
        if (source.providerType == ProviderType.localLlama) source.id,
    };
    var count = 0;
    var total = 0;
    for (final model in models) {
      if (!localSourceIds.contains(model.sourceId)) continue;
      count++;
      total += await localModelDiskUsage(model) ?? 0;
    }
    if (!mounted || count == 0) return;
    final label = count == 1 ? '1 local model' : '$count local models';
    setState(() => _summary = '$label · ${formatBytes(total)} on this device');
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.hardDrive300),
    title: const Text('Storage'),
    subtitle: Text(_summary ?? 'Files local models keep on this device'),
    trailing: const Icon(LucideIcons.chevronRight300),
    onTap: () => context.go('/settings/storage'),
  );
}

/// The Settings row into the Hardware page.
///
/// The subtitle reports installed memory once sampled — the number that
/// decides which local models this device can hold.
class _HardwareTile extends StatefulWidget {
  const _HardwareTile();

  @override
  State<_HardwareTile> createState() => _HardwareTileState();
}

class _HardwareTileState extends State<_HardwareTile> {
  String? _summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final memory = await llama.createSystemMemoryMonitor().sample();
    if (!mounted || memory.isEstimated) return;
    setState(
      () => _summary =
          '${formatBytes(memory.totalBytes)} unified memory, '
          '${formatBytes(memory.availableBytes)} free',
    );
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.cpu300),
    title: const Text('Hardware'),
    subtitle: Text(_summary ?? 'This machine, and live memory readings'),
    trailing: const Icon(LucideIcons.chevronRight300),
    onTap: () => context.go('/settings/hardware'),
  );
}

/// The Settings row into the About page.
///
/// The subtitle names the running version once the package-info cache has
/// loaded, so the number most support questions start with is one glance
/// away; before that (or where the service is absent) it describes the page.
class _AboutTile extends StatelessWidget {
  const _AboutTile({required this.appInfo});

  final AppInfo? appInfo;

  @override
  Widget build(BuildContext context) {
    final info = appInfo;
    final ready = info?.isReady ?? false;
    return ListTile(
      leading: const Icon(LucideIcons.info300),
      title: const Text('About'),
      subtitle: Text(
        ready
            ? 'Version ${info!.version} (${info.buildNumber})'
            : 'Version and open source licenses',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/about'),
    );
  }
}

/// The Settings row into the Memory page.
///
/// The subtitle names the embedding model in use, or says search is keyword
/// matching — the same at-a-glance state the other rows give their pages.
class _MemoryTile extends StatefulWidget {
  const _MemoryTile({required this.services});

  final ServiceProvider services;

  @override
  State<_MemoryTile> createState() => _MemoryTileState();
}

class _MemoryTileState extends State<_MemoryTile> {
  String? _modelLabel;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = widget.services.getRequiredService<EmbeddingSettings>();
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final selected = await settings.selectedModelId;
    if (selected == null) return;
    final model = await manager.sources.getModel(selected);
    if (!mounted || model == null) return;
    setState(() => _modelLabel = model.label);
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.brain300),
    title: const Text('Memory'),
    subtitle: Text(
      _modelLabel == null
          ? 'Agents search their memory by keyword matching'
          : 'Agents search their memory through "$_modelLabel"',
    ),
    trailing: const Icon(LucideIcons.chevronRight300),
    onTap: () => context.go('/settings/memory'),
  );
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

/// The Settings row into the Notifications page.
///
/// Live: the subtitle flips between the setup hint and "configured" the
/// moment credentials are saved or cleared.
class _NotificationsTile extends StatelessWidget {
  const _NotificationsTile({required this.settings});

  final PushoverSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => ListTile(
      leading: const Icon(LucideIcons.bellRing300),
      title: const Text('Notifications'),
      subtitle: Text(
        settings.isConfigured
            ? 'Configured — agents you allow can send push notifications'
            : 'Let agents send you push notifications through Pushover',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/settings/notifications'),
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

/// The Settings row into the paired-devices list.
///
/// Listed on every platform: revoking a pairing is host-side bookkeeping over
/// the key-value store, so it works even where hosting itself does not run.
class _PairedDevicesTile extends StatelessWidget {
  const _PairedDevicesTile();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.monitorSmartphone300),
    title: const Text('Paired devices'),
    subtitle: const Text(
      'Devices that can use your shared agents, and the way to remove them',
    ),
    trailing: const Icon(LucideIcons.chevronRight300),
    onTap: () => context.go('/settings/network/devices'),
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
/// Summarizes state rather than describing the destination: the subtitle
/// counts saved agents, and agents that cannot run — an agent whose model
/// or source has gone missing is the reason most people open this screen at
/// all — surface as a warning badge beside the chevron.
class _AgentCenterTile extends StatelessWidget {
  const _AgentCenterTile({required this.manager});

  final ConfiguredAgentsManager manager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AgentCenterSummary(
      manager: manager,
      builder: (context, summary) {
        final needsSetup = summary?.needsSetup ?? 0;
        return ListTile(
          leading: const Icon(LucideIcons.bot300),
          title: const Text('Agent Center'),
          subtitle: Text(switch (summary?.agents) {
            null => 'Agents, models, and sources',
            1 => '1 agent · models and sources',
            final count => '$count agents · models and sources',
          }),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (needsSetup > 0) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  needsSetup == 1 ? '1 needs setup' : '$needsSetup need setup',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              const Icon(LucideIcons.chevronRight300),
            ],
          ),
          onTap: () => context.go('/settings/agents'),
        );
      },
    );
  }
}

/// The Settings row into the Skills destination.
///
/// Live: the subtitle counts the stored skills, so whether agents have
/// anything to load is visible without leaving Settings.
class _SkillsTile extends StatefulWidget {
  const _SkillsTile({required this.skills});

  final SkillStore skills;

  @override
  State<_SkillsTile> createState() => _SkillsTileState();
}

class _SkillsTileState extends State<_SkillsTile> {
  late final Stream<List<StoredSkill>> _skills;

  @override
  void initState() {
    super.initState();
    _skills = widget.skills.watchAll();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<StoredSkill>>(
    stream: _skills,
    builder: (context, snapshot) => ListTile(
      leading: const Icon(LucideIcons.sparkles300),
      title: const Text('Skills'),
      subtitle: Text(switch (snapshot.data?.length) {
        null || 0 => 'Reusable skills agents can load on demand',
        1 => '1 skill agents can load on demand',
        final count => '$count skills agents can load on demand',
      }),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => context.go('/skills'),
    ),
  );
}

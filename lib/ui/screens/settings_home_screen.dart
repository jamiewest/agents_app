// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/app_reset.dart';
import '../../data/embedding_settings.dart';
import '../../data/theme_settings.dart';
import '../app_theme.dart';
import '../widgets/app_sliver_header.dart';
import '../widgets/page_body.dart';

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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Appearance',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _AppearanceSelector(
                    settings: services.getRequiredService<ThemeSettings>(),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                ListTile(
                  leading: const Icon(LucideIcons.radioTower300),
                  title: const Text('Share agents on the network'),
                  subtitle: const Text(
                    'Let paired devices use this device\'s agents (A2A)',
                  ),
                  trailing: const Icon(LucideIcons.chevronRight300),
                  onTap: () => context.go('/settings/hosting'),
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
                ListTile(
                  leading: const Icon(LucideIcons.brain300),
                  title: const Text('Memory embedding model'),
                  subtitle: const Text(
                    'How agent memory is searched. Defaults to keyword matching; '
                    'pick an OpenAI-compatible model for semantic recall.',
                  ),
                  trailing: const Icon(LucideIcons.chevronRight300),
                  onTap: () => _pickEmbeddingModel(context),
                ),
                const Divider(),
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

  Future<void> _pickEmbeddingModel(BuildContext context) async {
    final manager = services.getRequiredService<ConfiguredAgentsManager>();
    final settings = services.getRequiredService<EmbeddingSettings>();
    final sources = await manager.sources.listSources();
    final models = await manager.sources.listModels();
    final compatibleSourceIds = {
      for (final source in sources)
        if (source.providerType == ProviderType.openAiCompatible) source.id,
    };
    final candidates = [
      for (final model in models)
        if (compatibleSourceIds.contains(model.sourceId)) model,
    ];
    final current = await settings.selectedModelId;
    if (!context.mounted) return;

    final selection = await showDialog<(String?,)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Memory embedding model'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop((null,)),
            child: Row(
              children: [
                if (current == null) const Icon(LucideIcons.check300, size: 18),
                if (current == null) const SizedBox(width: 8),
                const Text('Keyword matching (no model)'),
              ],
            ),
          ),
          for (final model in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop((model.id,)),
              child: Row(
                children: [
                  if (current == model.id)
                    const Icon(LucideIcons.check300, size: 18),
                  if (current == model.id) const SizedBox(width: 8),
                  Flexible(child: Text(model.label)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selection == null) return;
    await settings.select(selection.$1);
  }
}

class _AppearanceSelector extends StatelessWidget {
  const _AppearanceSelector({required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(LucideIcons.sunMoon300),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(LucideIcons.sun300),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(LucideIcons.moon300),
              label: Text('Dark'),
            ),
          ],
          selected: {settings.mode},
          onSelectionChanged: (selection) => settings.setMode(selection.single),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final seed in AppThemeSeed.values)
              _SeedSwatch(
                seed: seed,
                selected: seed == settings.seed,
                onTap: () => settings.setSeed(seed),
              ),
          ],
        ),
      ],
    ),
  );
}

/// A tappable color dot for one [AppThemeSeed] choice.
class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final AppThemeSeed seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: seed.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: seed.color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  LucideIcons.check300,
                  size: 18,
                  color:
                      ThemeData.estimateBrightnessForColor(seed.color) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                )
              : null,
        ),
      ),
    );
  }
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

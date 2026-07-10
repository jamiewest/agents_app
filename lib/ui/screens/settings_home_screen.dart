// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  leading: const Icon(Symbols.smart_toy),
                  title: const Text('Agents & providers'),
                  subtitle: const Text(
                    'Model sources, API keys, models, and saved agents',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => context.go('/settings/agents'),
                ),
                ListTile(
                  leading: const Icon(Symbols.wifi_tethering),
                  title: const Text('Share agents on the network'),
                  subtitle: const Text(
                    'Let paired devices use this device\'s agents (A2A)',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => context.go('/settings/hosting'),
                ),
                // BLE is unavailable in the browser, so the wearable surface
                // only exists on native builds.
                if (!kIsWeb)
                  ListTile(
                    leading: const Icon(Symbols.watch),
                    title: const Text('Wearable device'),
                    subtitle: const Text(
                      'Connect the capture wearable, sync audio and images',
                    ),
                    trailing: const Icon(Symbols.chevron_right),
                    onTap: () => context.go('/settings/wearable'),
                  ),
                ListTile(
                  leading: const Icon(Symbols.receipt_long),
                  title: const Text('Logs & diagnostics'),
                  subtitle: const Text(
                    'Live app logs, prompts sent to models, and log levels',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => context.go('/settings/logging'),
                ),
                ListTile(
                  leading: const Icon(Symbols.psychology),
                  title: const Text('Memory embedding model'),
                  subtitle: const Text(
                    'How agent memory is searched. Defaults to keyword matching; '
                    'pick an OpenAI-compatible model for semantic recall.',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => _pickEmbeddingModel(context),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(
                    Symbols.restart_alt,
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
                if (current == null) const Icon(Symbols.check, size: 18),
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
                  if (current == model.id) const Icon(Symbols.check, size: 18),
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
              icon: Icon(Symbols.brightness_auto),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Symbols.light_mode),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Symbols.dark_mode),
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
                  Symbols.check,
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

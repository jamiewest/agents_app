// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/embedding_settings.dart';

/// The Settings destination: entry points into configuration surfaces.
class SettingsHomeScreen extends StatelessWidget {
  /// Creates a [SettingsHomeScreen].
  const SettingsHomeScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: const Text('Agents & providers'),
          subtitle: const Text(
            'Model sources, API keys, models, and saved agents',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/agents'),
        ),
        ListTile(
          leading: const Icon(Icons.person_add_alt_outlined),
          title: const Text('Add agent'),
          subtitle: const Text('Guided setup for a new agent'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/agents/add'),
        ),
        ListTile(
          leading: const Icon(Icons.wifi_tethering),
          title: const Text('Share agents on the network'),
          subtitle: const Text(
            'Let paired devices use this device\'s agents (A2A)',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/hosting'),
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Memory embedding model'),
          subtitle: const Text(
            'How agent memory is searched. Defaults to keyword matching; '
            'pick an OpenAI-compatible model for semantic recall.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickEmbeddingModel(context),
        ),
      ],
    ),
  );

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
                if (current == null) const Icon(Icons.check, size: 18),
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
                  if (current == model.id) const Icon(Icons.check, size: 18),
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

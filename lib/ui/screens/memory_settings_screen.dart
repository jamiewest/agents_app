// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../widgets/settings_page.dart';

/// The Memory sub-page: how agents search what they remember.
///
/// Memory search works out of the box with keyword matching; this page is
/// where an embedding model upgrades it to semantic scoring. The choice is
/// the app-wide [EmbeddingSettings] — the delegating scorer handed to the
/// vector store — so selecting here takes effect without rebuilding agents.
class MemorySettingsScreen extends StatefulWidget {
  /// Creates a [MemorySettingsScreen].
  const MemorySettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<MemorySettingsScreen> createState() => _MemorySettingsScreenState();
}

/// One selectable embedding model: the model plus its source's name, which
/// is what distinguishes two entries for the same provider model id.
typedef _Candidate = ({ModelConfig model, String sourceName});

class _MemorySettingsScreenState extends State<MemorySettingsScreen> {
  late final EmbeddingSettings _settings;
  late final ConfiguredAgentsManager _manager;
  StreamSubscription<void>? _changes;

  List<_Candidate>? _candidates;
  String? _selectedModelId;

  @override
  void initState() {
    super.initState();
    _settings = widget.services.getRequiredService<EmbeddingSettings>();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    // Models added or removed in the Agent Center should show up here
    // without leaving the page.
    _changes = _manager.configurationChanges.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Loads the selectable models and the persisted choice.
  ///
  /// Only models on OpenAI-compatible sources are listed — the embedding
  /// scorer speaks that provider's embeddings API and no other, so offering
  /// the rest would be offering choices that silently fall back to keyword
  /// matching.
  Future<void> _load() async {
    final models = await _manager.sources.listModels();
    final sources = await _manager.sources.listSources();
    final selected = await _settings.selectedModelId;
    final sourcesById = {for (final source in sources) source.id: source};
    final candidates = <_Candidate>[
      for (final model in models)
        if (sourcesById[model.sourceId] case final source?
            when source.providerType == ProviderType.openAiCompatible)
          (model: model, sourceName: source.displayName),
    ];
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _selectedModelId = selected;
    });
  }

  Future<void> _select(String? modelId) async {
    setState(() => _selectedModelId = modelId);
    await _settings.select(modelId);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    return SettingsPage(
      title: 'Memory',
      children: [
        const SettingsGroupCaption(
          'Agents remember things across conversations. When one searches '
          'its memory, matches are found by comparing words — or, with an '
          'embedding model, by meaning.',
        ),
        const SettingsGroupLabel('Memory search'),
        if (candidates == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          RadioGroup<String?>(
            groupValue: _selectedModelId,
            onChanged: (value) => unawaited(_select(value)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const RadioListTile<String?>(
                  value: null,
                  title: Text('Keyword matching'),
                  subtitle: Text(
                    'Compares the words themselves. Works offline and sends '
                    'nothing anywhere. The default.',
                  ),
                ),
                for (final candidate in candidates)
                  RadioListTile<String?>(
                    value: candidate.model.id,
                    title: Text(candidate.model.label),
                    subtitle: Text('Embeddings via ${candidate.sourceName}'),
                  ),
              ],
            ),
          ),
          if (candidates.isEmpty) ...[
            const SettingsGroupCaption(
              'Semantic search needs an embedding model from an '
              'OpenAI-compatible source — none of your sources qualify yet. '
              'Add one, then create a model entry for its embedding model '
              '(for example text-embedding-3-small, or a local server’s '
              'embedding model).',
            ),
            ListTile(
              leading: const Icon(LucideIcons.plug300),
              title: const Text('Open model sources'),
              trailing: const Icon(LucideIcons.chevronRight300),
              onTap: () => context.go('/settings/agents/sources'),
            ),
          ] else
            const SettingsGroupCaption(
              'Memory text is sent to the chosen source to be embedded. If '
              'the model or its source is later removed, search falls back '
              'to keyword matching.',
            ),
        ],
      ],
    );
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';

import '../data/demo_seed.dart';
import '../data/embedding_settings.dart';
import '../data/legacy_chat_migration.dart';
import '../data/local_model_store.dart';
import '../data/theme_settings.dart';
import '../data/thinking_settings.dart';
import '../ui/views/configured_agents/configured_agents.dart';

/// One-time application startup work: legacy data migration and optional
/// compile-time seeding, plus the "is the app usable yet" check that drives
/// the onboarding redirect.
class AppBootstrap {
  /// Creates an [AppBootstrap] over the app's services.
  AppBootstrap(this._services, {this._seedApiKey = '', this._seedModel = ''});

  final ServiceProvider _services;
  final String _seedApiKey;
  final String _seedModel;
  Future<void>? _ready;

  /// Runs migration and seeding exactly once; later calls await the first.
  Future<void> ensureInitialized() => _ready ??= _initialize();

  Future<void> _initialize() async {
    await LegacyChatMigration(
      keyValueStore: _services.getRequiredService<KeyValueStore>(),
      records: _services.getRequiredService<RecordStore>(),
    ).run();
    await _seedIfNeeded();
    if (DemoSeed.requested) await DemoSeed(_services).run();
    // Optional: not registered in minimal test containers.
    await _services.getService<EmbeddingSettings>()?.reload();
    await _services.getService<ThinkingSettings>()?.load();
    await _services.getService<ThemeSettings>()?.load();
    await _restoreLocalModelFiles();
  }

  /// Re-registers picked local GGUF files that were persisted to local
  /// storage in a previous session, so neither a web page reload nor a
  /// sandboxed native restart (where the originally picked path is no longer
  /// readable) requires the user to reselect them.
  Future<void> _restoreLocalModelFiles() async {
    if (!localModelPersistenceSupported) return;
    final manager = _services.getRequiredService<ConfiguredAgentsManager>();
    final fileModelIds = <String>{};
    for (final model in await manager.sources.listModels()) {
      if (model.settings['llama.modelSource'] != 'file') continue;
      fileModelIds.add(model.id);
      for (final kind in LlamaArtifactKind.values) {
        // Restore only artifacts the config still declares. A stored copy
        // can outlive its setting — e.g. a draft model removed in the model
        // editor — and registering it anyway silently re-enables the
        // artifact (the registered selection beats the persisted settings
        // when the session loads). Delete such orphans instead.
        final declared =
            model.settings[_artifactFileNameKey(kind)]?.trim() ?? '';
        if (declared.isEmpty) {
          await deleteLocalModelFiles(model.id, kindKey: kind.name);
          continue;
        }
        // A live selection made this session always wins.
        if (selectedLlamaModelFilePathFor(model.id, kind: kind) != null) {
          continue;
        }
        final location = await restoreLocalModelLocation(
          modelId: model.id,
          kindKey: kind.name,
        );
        if (location != null) {
          registerSelectedLlamaModelFile(model.id, location, kind: kind);
        }
      }
    }
    // Reclaim storage from models deleted (or picked-then-cancelled) in a way
    // that skipped the normal delete path.
    await pruneLocalModelFiles(fileModelIds);
  }

  /// The model-settings key holding the picked file name for [kind]; empty
  /// or absent means the config no longer uses that artifact.
  static String _artifactFileNameKey(LlamaArtifactKind kind) => switch (kind) {
    LlamaArtifactKind.model => 'llama.modelFileName',
    LlamaArtifactKind.mmproj => 'llama.mmprojFileName',
    LlamaArtifactKind.draft => 'llama.draftModelFileName',
  };

  /// Whether at least one saved agent can actually run: its model and
  /// source resolve, and a key is stored when the source needs one.
  Future<bool> hasUsableAgent() async {
    await ensureInitialized();
    final manager = _services.getRequiredService<ConfiguredAgentsManager>();
    for (final agent in await manager.agents.listAgents()) {
      final model = await manager.sources.getModel(agent.modelId);
      if (model == null) continue;
      final source = await manager.sources.getSource(model.sourceId);
      if (source == null) continue;
      if (source.providerType.requiresApiKey) {
        final key = await manager.getSourceApiKey(source.id);
        if (key == null || key.isEmpty) continue;
      }
      return true;
    }
    return false;
  }

  Future<void> _seedIfNeeded() async {
    if (_seedApiKey.trim().isEmpty) return;
    final manager = _services.getRequiredService<ConfiguredAgentsManager>();
    final existing = await manager.sources.listSources();
    if (existing.isNotEmpty) return;

    const sourceId = 'seed-anthropic';
    const modelId = 'seed-anthropic-model';
    await manager.saveSource(
      const ModelSourceConfig(
        id: sourceId,
        providerType: ProviderType.anthropic,
        displayName: 'Anthropic (seeded)',
      ),
      apiKey: _seedApiKey,
    );
    await manager.saveModel(
      ModelConfig(
        id: modelId,
        sourceId: sourceId,
        modelId: _seedModel,
        displayName: 'Claude',
      ),
    );
    await manager.saveAgent(
      const SavedAgentConfig(
        id: 'seed-anthropic-agent',
        name: 'Claude',
        modelId: modelId,
        description: 'A helpful assistant.',
        instructions: 'You are a helpful, concise assistant.',
      ),
    );
  }
}

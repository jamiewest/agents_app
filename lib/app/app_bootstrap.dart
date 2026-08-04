// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tor_flutter/tor_flutter.dart';

import '../data/demo_seed.dart';
import '../features/local_models/downloaded_model_artifacts.dart';
import '../features/inventory/inventory_access_settings.dart';
import '../features/tor/tor_settings.dart';
import '../features/tor/tor_sharing_settings.dart';
import '../data/legacy/legacy_chat_migration.dart';
import '../features/local_models/local_model_store.dart';
import '../data/theme_settings.dart';
import '../chat_toolkit/views/configured_agents/configured_agents.dart';

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
    await _services.getService<PushoverSettings>()?.load();
    await _services.getService<WebSearchSettings>()?.load();
    await _services.getService<WebSearchTraceLog>()?.load();
    await _services.getService<InventoryAccessSettings>()?.load();
    await _services.getService<UserProfileSettings>()?.load();
    // Brings the A2A host back up when agents were left shared, so a switch
    // that reads "on" means the agent is actually reachable.
    await _services.getService<NetworkSharingSettings>()?.load();
    // Where Arti keeps its consensus cache, guard state, and its own copy of
    // the onion key. Resolved here rather than at registration because the
    // path is only available asynchronously, and the runtime cannot start
    // without it.
    await _resolveTorDataDirectory();
    // Brings Tor back up when it was left on, so a switch that reads "on"
    // means onion addresses are actually reachable. Starts in the background:
    // bootstrap takes tens of seconds and must not hold up the first frame.
    await _services.getService<TorSettings>()?.load();
    // Republishes the onion service, and reads back the address the user has
    // already shared, so a peer's saved pairing keeps working. Must follow
    // the host coming up: there is no local port to publish before that.
    await _services.getService<TorSharingSettings>()?.load();
    // Runs left `running` by a crash or force-quit are recovered before any
    // new run can start; a sweep after that point would mark a legitimately
    // in-flight run as interrupted.
    await _services.getService<AgentRunTelemetryStore>()?.recoverInterrupted();
    await _restoreLocalModelFiles();
    await _pruneDownloadedModelArtifacts();
  }

  /// Points Tor at a private directory under application support.
  ///
  /// Guard state must persist across launches — churning guards every start is
  /// bad for anonymity — so this is a stable location rather than a temporary
  /// one. Absent when no Tor backend is registered, which is the normal case
  /// on platforms that cannot host.
  Future<void> _resolveTorDataDirectory() async {
    // The web backend keeps its own state in the browser and has no directory
    // to be given, while path_provider throws when asked for one. Checked
    // before the registration test rather than relying on it: a Tor backend
    // *is* registered on web now, and the throw happened here — inside the
    // future the router waits on — so the whole app stayed blank with nothing
    // logged.
    if (kIsWeb) return;
    final options = _services.getService<TorOptions>();
    if (options == null || options.dataDirectory != null) return;
    // Arti creates the tree itself, so there is nothing to make here and no
    // reason to pull dart:io into a file that also compiles for web.
    final support = await getApplicationSupportDirectory();
    options.dataDirectory = '${support.path}/tor';
  }

  /// Reclaims managed storage from downloaded GGUFs no configured model asks
  /// for any more.
  ///
  /// The web counterpart of the prune inside [_restoreLocalModelFiles], and
  /// the safety net behind the per-model deletes: a model removed by an
  /// older build (or by a path that never learned to clean up) can have left
  /// gigabytes behind, and until they go the browser keeps refusing the next
  /// download for want of quota. Runs before any model loads, so nothing it
  /// deletes is in use.
  Future<void> _pruneDownloadedModelArtifacts() async {
    if (!downloadedModelArtifactsSupported) return;
    final manager = _services.getRequiredService<ConfiguredAgentsManager>();
    await pruneDownloadedModelArtifacts(
      downloadedArtifactKeysFor(await manager.sources.listModels()),
    );
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

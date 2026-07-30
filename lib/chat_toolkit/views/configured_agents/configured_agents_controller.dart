// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';

import '../../../features/local_models/downloaded_model_artifacts.dart';
import '../../../features/local_models/local_model_store.dart';

/// Mutable view-model for the configured-agents UI.
///
/// Loads sources, models, and agents from a [ConfiguredAgentsManager], exposes
/// them to widgets, and funnels every mutation through the manager so that
/// referential-integrity and secret handling stay in one place. Configuration
/// errors are caught and surfaced via [lastError] rather than thrown into the
/// widget tree.
class ConfiguredAgentsController extends ChangeNotifier {
  /// Creates a controller over [manager].
  ConfiguredAgentsController(this.manager);

  /// The coordinator backing all reads and mutations.
  final ConfiguredAgentsManager manager;

  List<ModelSourceConfig> _sources = const [];
  List<ModelConfig> _models = const [];
  List<SavedAgentConfig> _agents = const [];
  bool _loading = false;

  /// All saved sources.
  List<ModelSourceConfig> get sources => _sources;

  /// All saved models.
  List<ModelConfig> get models => _models;

  /// All saved agents.
  List<SavedAgentConfig> get agents => _agents;

  /// Whether a load is in progress.
  bool get loading => _loading;

  /// Loads all configuration from storage.
  Future<void> load() async {
    _loading = true;
    notifyListeners();
    _sources = await manager.sources.listSources();
    _models = await manager.sources.listModels();
    _agents = await manager.agents.listAgents();
    _loading = false;
    notifyListeners();
  }

  /// Returns whether a non-empty API key is stored for [sourceId].
  Future<bool> hasApiKey(String sourceId) => manager.hasSourceApiKey(sourceId);

  /// Saves [source] (and optional [apiKey]) then reloads.
  Future<String?> saveSource(ModelSourceConfig source, {String? apiKey}) =>
      _run(() => manager.saveSource(source, apiKey: apiKey));

  /// Deletes the source [id], optionally cascading, then reloads.
  ///
  /// A cascade takes the source's models with it, so their storage goes too:
  /// the models are read before the delete, because afterwards there is
  /// nothing left to say which artifacts were theirs.
  Future<String?> deleteSource(String id, {bool cascade = false}) =>
      _run(() async {
        final doomed = cascade
            ? [
                for (final model in await manager.sources.listModels())
                  if (model.sourceId == id) model,
              ]
            : const <ModelConfig>[];
        await manager.deleteSource(id, cascade: cascade);
        for (final model in doomed) {
          await deleteLocalModelFiles(model.id);
          await deleteDownloadedModelArtifacts(model);
        }
      });

  /// Saves [model] then reloads.
  Future<String?> saveModel(ModelConfig model) =>
      _run(() => manager.saveModel(model));

  /// Deletes the model [id], optionally cascading, then reloads.
  ///
  /// Also removes the model's stored GGUFs so a deleted local model does not
  /// leave gigabytes stranded in storage — both the files picked into the
  /// app's own storage and, on the web, the ones the runtime downloaded into
  /// managed storage. The latter is keyed by URL, which only the model's
  /// settings record, so it is read before the config is gone.
  Future<String?> deleteModel(String id, {bool cascade = false}) =>
      _run(() async {
        final model = await manager.sources.getModel(id);
        await manager.deleteModel(id, cascade: cascade);
        await deleteLocalModelFiles(id);
        if (model != null) await deleteDownloadedModelArtifacts(model);
      });

  /// Saves [agent] then reloads.
  Future<String?> saveAgent(SavedAgentConfig agent) =>
      _run(() => manager.saveAgent(agent));

  /// Deletes the agent [id], optionally cascading, then reloads.
  Future<String?> deleteAgent(String id, {bool cascade = false}) =>
      _run(() => manager.deleteAgent(id, cascade: cascade));

  /// Runs [action] and reloads. Returns `null` on success or an error
  /// message when the action was rejected or failed.
  ///
  /// Reloading happens even on failure — a partially applied mutation
  /// (e.g. a record removed before a platform storage call threw) must
  /// still be reflected in the lists rather than leaving the UI stale.
  Future<String?> _run(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on ConfiguredAgentException catch (error) {
      return error.message;
    } catch (error) {
      return 'Something went wrong: $error';
    } finally {
      await load();
    }
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';

import '../../../data/local_model_store.dart';

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
  Future<String?> deleteSource(String id, {bool cascade = false}) =>
      _run(() => manager.deleteSource(id, cascade: cascade));

  /// Saves [model] then reloads.
  Future<String?> saveModel(ModelConfig model) =>
      _run(() => manager.saveModel(model));

  /// Deletes the model [id], optionally cascading, then reloads.
  ///
  /// Also removes any browser-persisted local GGUF files for the model so a
  /// deleted local model does not leave gigabytes stranded in storage.
  Future<String?> deleteModel(String id, {bool cascade = false}) => _run(() async {
    await manager.deleteModel(id, cascade: cascade);
    await deleteLocalModelFiles(id);
  });

  /// Saves [agent] then reloads.
  Future<String?> saveAgent(SavedAgentConfig agent) =>
      _run(() => manager.saveAgent(agent));

  /// Deletes the agent [id], optionally cascading, then reloads.
  Future<String?> deleteAgent(String id, {bool cascade = false}) =>
      _run(() => manager.deleteAgent(id, cascade: cascade));

  /// Runs [action], reloading on success. Returns `null` on success or the
  /// [ConfiguredAgentException] message when the action was rejected.
  Future<String?> _run(Future<void> Function() action) async {
    try {
      await action();
      await load();
      return null;
    } on ConfiguredAgentException catch (error) {
      return error.message;
    }
  }
}

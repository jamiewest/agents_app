// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;

/// The app's embedding-model choice, exposed as a delegating [MemoryScorer].
///
/// Memory search works out of the box with keyword matching; picking an
/// OpenAI-compatible model in Settings upgrades scoring to embeddings.
/// Because this IS the scorer handed to the vector store, changing the
/// setting takes effect via [reload] without rebuilding agents.
class EmbeddingSettings extends MemoryScorer {
  /// Creates an [EmbeddingSettings].
  EmbeddingSettings({required this._keyValueStore, required this._manager});

  /// The setting key holding the selected [ModelConfig] id.
  static const String settingKey = 'agents_app.settings.embedding_model_id';

  final KeyValueStore _keyValueStore;
  final ConfiguredAgentsManager _manager;
  MemoryScorer _active = const KeywordOverlapScorer();

  /// The selected embedding model id, or `null` for keyword matching.
  Future<String?> get selectedModelId => _keyValueStore.read(settingKey);

  /// Persists the embedding model choice and applies it.
  Future<void> select(String? modelId) async {
    if (modelId == null) {
      await _keyValueStore.delete(settingKey);
    } else {
      await _keyValueStore.write(settingKey, modelId);
    }
    await reload();
  }

  /// Re-resolves the active scorer from the stored setting.
  ///
  /// Falls back to keyword matching when the setting is absent or its
  /// model/source/key no longer resolve.
  Future<void> reload() async {
    _active = await _resolve() ?? const KeywordOverlapScorer();
  }

  Future<MemoryScorer?> _resolve() async {
    try {
      final modelId = await selectedModelId;
      if (modelId == null || modelId.isEmpty) return null;
      final model = await _manager.sources.getModel(modelId);
      if (model == null) return null;
      final source = await _manager.sources.getSource(model.sourceId);
      if (source == null ||
          source.providerType != ProviderType.openAiCompatible) {
        return null;
      }
      final apiKey = await _manager.getSourceApiKey(source.id) ?? '';
      final endpoint = source.endpoint;
      return EmbeddingGeneratorScorer(
        ai.OpenAIEmbeddingGenerator(
          model.modelId,
          apiKey,
          options: endpoint == null || endpoint.isEmpty
              ? null
              : ai.OpenAIClientOptions(endpoint: Uri.parse(endpoint)),
        ),
      );
    } catch (e, s) {
      developer.log(
        'Failed to resolve the embedding model; falling back to keyword '
        'matching.',
        name: 'agents_app.memory',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  @override
  Future<List<double>?> embed(String text) => _active.embed(text);

  @override
  double score({
    required String queryText,
    required String recordText,
    List<double>? queryVector,
    List<double>? recordVector,
  }) => _active.score(
    queryText: queryText,
    recordText: recordText,
    queryVector: queryVector,
    recordVector: recordVector,
  );
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Web disk accounting for local models.
///
/// Downloads live in the llama_cpp_flutter managed artifact store, which
/// reports sizes; picked files live in OPFS behind
/// `local_model_store_web.dart`, which does not, so a picked-file model's
/// usage is unknown here. Deletion covers both, through the same calls the
/// model-delete path uses.
library;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart'
    show createArtifactStore;

import 'downloaded_model_artifacts.dart';
import 'local_model_store.dart';

/// Whether this platform can report or reclaim local-model disk usage.
bool get localModelDiskSupported => true;

/// The directory local-model bytes live under, or null when the platform
/// has no user-visible path for it. OPFS has none.
Future<String?> localModelStorageRootPath() async => null;

/// Bytes on disk for [model] across every store, or null when unknown.
Future<int?> localModelDiskUsage(ModelConfig model) async {
  final keys = downloadedArtifactKeysOf(model);
  // A picked-file model's bytes sit in OPFS, which exposes no size query.
  if (keys.isEmpty) return null;
  try {
    final store = createArtifactStore();
    var total = 0;
    for (final key in keys) {
      final artifact = await store.lookup(key);
      if (artifact != null) total += artifact.sizeBytes;
    }
    return total;
  } catch (_) {
    return null;
  }
}

/// Deletes [model]'s stored bytes from every store, keeping its
/// configuration.
Future<void> deleteLocalModelBytes(ModelConfig model) async {
  await deleteLocalModelFiles(model.id);
  await deleteDownloadedModelArtifacts(model);
}

/// Deletes native download directories for every model **not** in
/// [keepModelIds]. A no-op on web, whose downloads are pruned by key
/// through `pruneDownloadedModelArtifacts` instead.
Future<void> pruneLocalModelDownloads(Set<String> keepModelIds) async {}

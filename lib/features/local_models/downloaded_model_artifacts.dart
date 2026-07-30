// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Lifecycle of the GGUFs the **web** runtime downloads for URL-backed local
/// models.
///
/// Two different OPFS directories hold local-model bytes in the browser, and
/// only one of them was ever cleaned up:
///
/// * `local_models` — files the user *picked*, copied there by
///   `local_model_store_web.dart`. `deleteLocalModelFiles` and
///   `pruneLocalModelFiles` own these.
/// * the llama_cpp_flutter artifact directory — files the runtime
///   *downloaded* when `loadModel` was handed a `ModelSpec` with URLs and no
///   local path (see `main.dart`'s `kIsWeb` load branch). Nothing in the app
///   touched these, so deleting a model — or even resetting all app data —
///   left the gigabytes behind, and the quota error the package raises
///   ("Delete a model and try again") had no delete that would help.
///
/// This library closes that gap through the package's public [ArtifactStore],
/// keyed the same way the runtime keys its downloads: `stableArtifactFileName`
/// of the artifact URL.
///
/// Web-only by design. On native the app downloads through `DownloadService`
/// into its own `local_llama/<modelId>` directories; the native artifact
/// store points somewhere the app never writes, and pruning it would be
/// deleting another owner's files.
library;

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:llama_cpp_flutter/gguf.dart' show stableArtifactFileName;
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart'
    show ArtifactStore, createArtifactStore;

/// Model settings naming an artifact the runtime downloads by URL.
///
/// Mirrors the keys `main.dart` reads when it builds a `ModelSpec`; a key
/// that drifts from that list would strand exactly the artifact it names.
const List<String> _artifactUrlSettings = <String>[
  'llama.modelUrl',
  'llama.mmprojUrl',
  'llama.draftModelUrl',
];

/// Whether downloaded artifacts are managed by this app on this platform.
bool get downloadedModelArtifactsSupported => kIsWeb;

/// The managed-storage keys for every artifact [model] declares by URL.
///
/// Empty for a picked-file model, and for any model whose source is not a
/// local llama URL — neither downloads anything.
Set<String> downloadedArtifactKeysOf(ModelConfig model) {
  // Absent means "url": the setting postdates the first URL-only models, and
  // `main.dart` applies the same default when resolving a model's location.
  final source = model.settings['llama.modelSource']?.trim() ?? '';
  if (source == 'file') return const <String>{};
  final keys = <String>{};
  for (final setting in _artifactUrlSettings) {
    final value = model.settings[setting]?.trim();
    if (value == null || value.isEmpty) continue;
    final url = Uri.tryParse(value);
    // A URL too malformed to parse never became a download either.
    if (url == null) continue;
    keys.add(stableArtifactFileName(url));
  }
  return keys;
}

/// The managed-storage keys every model in [models] still needs.
Set<String> downloadedArtifactKeysFor(Iterable<ModelConfig> models) => <String>{
  for (final model in models) ...downloadedArtifactKeysOf(model),
};

/// Deletes the downloaded artifacts [model] declared, freeing their bytes.
///
/// Also clears any interrupted transfer of them, so a failed download does
/// not keep occupying quota after the model that wanted it is gone.
Future<void> deleteDownloadedModelArtifacts(ModelConfig model) async {
  final keys = downloadedArtifactKeysOf(model);
  if (keys.isEmpty) return;
  await _delete(keys);
}

/// Deletes every stored artifact whose key is **not** in [keepKeys].
///
/// The download counterpart of `pruneLocalModelFiles`: reclaims storage from
/// models deleted (or whose URL was edited) in a way that skipped the normal
/// delete path. Pass an empty set to clear everything.
///
/// Only *complete* artifacts can be found this way — [ArtifactStore.list]
/// omits interrupted transfers, and their keys cannot be recovered once the
/// model that names them is gone. A partial left by a model still configured
/// is kept regardless, since the next load resumes from it.
Future<void> pruneDownloadedModelArtifacts(Set<String> keepKeys) async {
  final store = _store();
  if (store == null) return;
  try {
    final stored = await store.list();
    final stale = <String>{
      for (final artifact in stored)
        if (!keepKeys.contains(artifact.key)) artifact.key,
    };
    await _delete(stale, store: store);
  } catch (error, stackTrace) {
    _log('Failed to list downloaded model artifacts', error, stackTrace);
  }
}

/// Whether every URL in [urls] is stored as a complete artifact in the
/// runtime's managed storage.
///
/// The startup warm-up's web presence probe. Only artifacts the web runtime
/// downloaded through its OPFS route — files over the wasm32 single-file
/// limit — are visible here; smaller models live in wllama's own URL cache,
/// which exposes no presence query. Unknown therefore reports as absent,
/// the direction the warm-up treats as "skip rather than download".
Future<bool> downloadedArtifactsInManagedStorage(Iterable<Uri> urls) async {
  final store = _store();
  if (store == null) return false;
  try {
    final stored = await store.list();
    final keys = <String>{for (final artifact in stored) artifact.key};
    return urls.every((url) => keys.contains(stableArtifactFileName(url)));
  } catch (error, stackTrace) {
    _log('Failed to list downloaded model artifacts', error, stackTrace);
    return false;
  }
}

/// Deletes [keys], surviving a per-key failure so one bad entry cannot strand
/// the rest.
Future<void> _delete(Set<String> keys, {ArtifactStore? store}) async {
  final target = store ?? _store();
  if (target == null) return;
  for (final key in keys) {
    try {
      await target.delete(key);
    } catch (error, stackTrace) {
      _log('Failed to delete downloaded artifact "$key"', error, stackTrace);
    }
  }
}

/// Managed storage, or null when this platform does not manage downloads.
ArtifactStore? _store() =>
    downloadedModelArtifactsSupported ? createArtifactStore() : null;

void _log(String message, Object error, StackTrace stackTrace) => developer.log(
  message,
  name: 'agents_app.downloaded_model_artifacts',
  error: error,
  stackTrace: stackTrace,
);

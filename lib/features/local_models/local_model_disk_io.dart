// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Native disk accounting for local models.
///
/// Sums and deletes across both native byte stores: the picked-file copies
/// under `local_models/` (see `local_model_store_io.dart`, whose base path
/// and directory naming this library reuses so the two can never disagree)
/// and the download service's `local_llama/<modelId>` directories.
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';

import 'local_model_store_io.dart';

/// The download service's directory, matching the `DownloadRequest`s built
/// in `local_llama_agent_factory.dart` (`directory: 'local_llama/$modelId'`
/// under the application-support base).
const String _downloadsDirName = 'local_llama';

/// Whether this platform can report or reclaim local-model disk usage.
bool get localModelDiskSupported => true;

/// The directory local-model bytes live under, or null when the platform
/// has no user-visible path for it.
Future<String?> localModelStorageRootPath() => localModelStorageBasePath();

/// Bytes on disk for [model] across every store, or null when unknown.
///
/// Zero means "no files stored", which for a URL model reads as "not
/// downloaded yet" and for a picked-file model as "needs its file picked".
Future<int?> localModelDiskUsage(ModelConfig model) async {
  try {
    var total = 0;
    for (final dir in await _modelDirs(model.id)) {
      total += _directorySizeBytes(dir);
    }
    return total;
  } catch (error, stack) {
    _log('Failed to measure local model ${model.id}', error, stack);
    return null;
  }
}

/// Deletes [model]'s stored bytes from every store, keeping its
/// configuration.
Future<void> deleteLocalModelBytes(ModelConfig model) async {
  await deleteLocalModelFiles(model.id);
  try {
    final dir = await _downloadDir(model.id);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (error, stack) {
    _log('Failed to delete downloads for model ${model.id}', error, stack);
  }
}

/// Deletes native download directories for every model **not** in
/// [keepModelIds].
///
/// The download-store counterpart of `pruneLocalModelFiles`: models removed
/// by an older build — or any path that never learned about the download
/// directories — left their GGUFs stranded here with nothing else to
/// reclaim them. Best-effort.
Future<void> pruneLocalModelDownloads(Set<String> keepModelIds) async {
  try {
    final root = Directory(
      '${await localModelStorageBasePath()}/$_downloadsDirName',
    );
    if (!root.existsSync()) return;
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (keepModelIds.contains(name)) continue;
      entry.deleteSync(recursive: true);
    }
  } catch (error, stack) {
    _log('Failed to prune orphaned model downloads', error, stack);
  }
}

Future<List<Directory>> _modelDirs(String modelId) async => [
  Directory(await localModelStoreDirPath(modelId)),
  await _downloadDir(modelId),
];

Future<Directory> _downloadDir(String modelId) async => Directory(
  '${await localModelStorageBasePath()}/$_downloadsDirName/$modelId',
);

int _directorySizeBytes(Directory dir) {
  if (!dir.existsSync()) return 0;
  var total = 0;
  for (final entry in dir.listSync(recursive: true, followLinks: false)) {
    if (entry is File) total += entry.lengthSync();
  }
  return total;
}

void _log(String message, Object error, StackTrace stack) => developer.log(
  message,
  name: 'agents_app.local_model_disk',
  error: error,
  stackTrace: stack,
);

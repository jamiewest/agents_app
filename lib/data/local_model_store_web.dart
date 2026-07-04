// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Web implementation of the local model store, backed by the Origin Private
/// File System (OPFS).
///
/// Picked GGUF files are streamed into OPFS keyed by the model config id and
/// artifact kind, so a page reload can restore them as fresh `blob:` object
/// URLs instead of forcing the user to re-pick (or the app to re-download).
library;

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:developer' as developer;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const String _rootDirName = 'local_models';

/// Whether persistent local-model storage is available on this platform.
bool get localModelPersistenceSupported => true;

/// Streams the file at [sourcePath] into OPFS under `[modelId]/[kindKey]`.
///
/// [sourcePath] must be a live `blob:` URL (a freshly picked file this
/// session). The copy is streamed, never buffered whole into the Dart/JS
/// heap, so a multi-gigabyte model does not exhaust memory. Best-effort:
/// failures are logged and swallowed so a storage hiccup never blocks saving
/// a model.
Future<void> persistLocalModelFile({
  required String modelId,
  required String kindKey,
  required String sourcePath,
}) async {
  try {
    final root = await _rootDirectory(create: true);
    final modelDir = await root!
        .getDirectoryHandle(
          _safe(modelId),
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    final fileHandle = await modelDir
        .getFileHandle(kindKey, web.FileSystemGetFileOptions(create: true))
        .toDart;
    final writable = await fileHandle.createWritable().toDart;

    final response = await web.window.fetch(sourcePath.toJS).toDart;
    final body = response.body;
    if (body != null) {
      // Stream straight from the blob into OPFS; pipeTo closes the sink.
      await body.pipeTo(writable).toDart;
    } else {
      final blob = await response.blob().toDart;
      await writable.write(blob as JSAny).toDart;
      await writable.close().toDart;
    }

    // Ask the browser not to evict OPFS under storage pressure; without this
    // the persisted file can silently disappear and the feature regresses.
    await web.window.navigator.storage.persist().toDart;
  } catch (error, stack) {
    developer.log(
      'Failed to persist local model $modelId/$kindKey',
      name: 'local_model_store',
      error: error,
      stackTrace: stack,
    );
  }
}

/// Returns a fresh, fetchable `blob:` URL for a persisted file, or null if
/// none is stored (or OPFS is unavailable).
Future<String?> restoreLocalModelLocation({
  required String modelId,
  required String kindKey,
}) async {
  try {
    final root = await _rootDirectory(create: false);
    if (root == null) return null;
    final modelDir = await root.getDirectoryHandle(_safe(modelId)).toDart;
    final fileHandle = await modelDir.getFileHandle(kindKey).toDart;
    final file = await fileHandle.getFile().toDart;
    return web.URL.createObjectURL(file);
  } catch (_) {
    // NotFoundError (nothing stored) and unsupported browsers both land here.
    return null;
  }
}

/// Deletes the persisted file(s) for [modelId] — a single [kindKey], or the
/// whole model directory when [kindKey] is null.
Future<void> deleteLocalModelFiles(String modelId, {String? kindKey}) async {
  try {
    final root = await _rootDirectory(create: false);
    if (root == null) return;
    if (kindKey == null) {
      await root
          .removeEntry(
            _safe(modelId),
            web.FileSystemRemoveOptions(recursive: true),
          )
          .toDart;
    } else {
      final modelDir = await root.getDirectoryHandle(_safe(modelId)).toDart;
      await modelDir.removeEntry(kindKey).toDart;
    }
  } catch (_) {
    // Already gone, or OPFS unavailable — nothing to do.
  }
}

/// Deletes persisted files for every model **not** in [keepModelIds].
///
/// Called at startup to reclaim storage from models that were removed (or
/// whose editor was cancelled after a file was picked) in a way that skipped
/// the normal delete path. Best-effort.
Future<void> pruneLocalModelFiles(Set<String> keepModelIds) async {
  try {
    final root = await _rootDirectory(create: false);
    if (root == null) return;
    final keep = keepModelIds.map(_safe).toSet();
    for (final name in await _entryNames(root)) {
      if (keep.contains(name)) continue;
      await root
          .removeEntry(name, web.FileSystemRemoveOptions(recursive: true))
          .toDart;
    }
  } catch (error, stack) {
    developer.log(
      'Failed to prune orphaned local models',
      name: 'local_model_store',
      error: error,
      stackTrace: stack,
    );
  }
}

/// Lists the entry names directly under [dir] by driving its async iterator.
///
/// `FileSystemDirectoryHandle` is an async iterable of names via `keys()`;
/// package:web has no typed binding, so the JS async iterator is stepped
/// manually.
Future<List<String>> _entryNames(web.FileSystemDirectoryHandle dir) async {
  final names = <String>[];
  final iterator = dir.callMethod<JSObject>('keys'.toJS);
  while (true) {
    final result = await iterator
        .callMethod<JSPromise<JSObject>>('next'.toJS)
        .toDart;
    if (result.getProperty<JSBoolean>('done'.toJS).toDart) break;
    final value = result.getProperty<JSString?>('value'.toJS);
    if (value != null) names.add(value.toDart);
  }
  return names;
}

/// Resolves the `local_models` directory, creating it when [create] is true.
///
/// Returns null when OPFS is unavailable or the directory does not exist and
/// [create] is false.
Future<web.FileSystemDirectoryHandle?> _rootDirectory({
  required bool create,
}) async {
  try {
    final opfs = await web.window.navigator.storage.getDirectory().toDart;
    return await opfs
        .getDirectoryHandle(
          _rootDirName,
          web.FileSystemGetDirectoryOptions(create: create),
        )
        .toDart;
  } catch (_) {
    return null;
  }
}

/// Makes [id] safe to use as an OPFS entry name.
String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

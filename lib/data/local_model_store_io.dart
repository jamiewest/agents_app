// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Native implementation of the local model store, backed by the app's
/// Application Support directory.
///
/// Picked GGUF files are copied into `<app support>/local_models/<modelId>/`
/// so a sandboxed build (macOS/iOS) can still open them after a restart: the
/// picked path — typically somewhere like ~/Downloads — is only readable
/// while the file picker's sandbox grant is alive, but the app's own
/// container always is.
///
/// Directory bookkeeping uses synchronous `dart:io` calls: they are cheap,
/// and widget tests (whose fake event loop never completes real async I/O)
/// can then drive every code path except the one genuinely long operation —
/// the model file copy, which stays async so multi-gigabyte files never
/// block the UI isolate.
library;

import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const String _rootDirName = 'local_models';

/// Overrides the store's base directory (normally Application Support) so
/// tests can run without platform channels.
@visibleForTesting
Directory? debugLocalModelStoreRoot;

/// Cached Application Support lookup: one platform-channel call per run.
Future<Directory>? _baseDir;

/// Whether persistent local-model storage is available on this platform.
bool get localModelPersistenceSupported => true;

/// Copies the file at [sourcePath] into the store under
/// `[modelId]/[kindKey]`.
///
/// The copy lands under a scratch name first and is renamed into place, so
/// an app killed mid-copy can never leave a truncated file where
/// [restoreLocalModelLocation] would find it. Best-effort: failures (disk
/// full, source vanished) are logged and swallowed so a storage hiccup never
/// blocks saving a model.
Future<void> persistLocalModelFile({
  required String modelId,
  required String kindKey,
  required String sourcePath,
}) async {
  try {
    final source = File(sourcePath);
    final dest = File('${await _modelDirPath(modelId, create: true)}/$kindKey');
    // Re-saving a restored selection: the file is already the stored copy.
    if (source.absolute.path == dest.absolute.path) return;
    final partial = await source.copy('${dest.path}.part');
    partial.renameSync(dest.path);
  } catch (error, stack) {
    developer.log(
      'Failed to persist local model $modelId/$kindKey',
      name: 'local_model_store',
      error: error,
      stackTrace: stack,
    );
  }
}

/// Returns the absolute path of the stored copy for `[modelId]/[kindKey]`,
/// or null when nothing is stored.
Future<String?> restoreLocalModelLocation({
  required String modelId,
  required String kindKey,
}) async {
  try {
    final file = File(
      '${await _modelDirPath(modelId, create: false)}/$kindKey',
    );
    return file.existsSync() ? file.path : null;
  } catch (_) {
    return null;
  }
}

/// Deletes the stored file(s) for [modelId] — a single [kindKey], or the
/// whole model directory when [kindKey] is null.
Future<void> deleteLocalModelFiles(String modelId, {String? kindKey}) async {
  try {
    final dir = Directory(await _modelDirPath(modelId, create: false));
    if (kindKey == null) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    }
    final file = File('${dir.path}/$kindKey');
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    // Already gone — nothing to do.
  }
}

/// Deletes stored files for every model **not** in [keepModelIds].
///
/// Called at startup to reclaim disk from models that were removed (or whose
/// editor was cancelled after a file was picked) in a way that skipped the
/// normal delete path. Best-effort.
Future<void> pruneLocalModelFiles(Set<String> keepModelIds) async {
  try {
    final root = Directory(await _rootPath());
    if (!root.existsSync()) return;
    final keep = keepModelIds.map(_safe).toSet();
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (keep.contains(name)) continue;
      entry.deleteSync(recursive: true);
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

Future<String> _rootPath() async {
  final override = debugLocalModelStoreRoot;
  final base =
      override ?? await (_baseDir ??= getApplicationSupportDirectory());
  return '${base.path}/$_rootDirName';
}

Future<String> _modelDirPath(String modelId, {required bool create}) async {
  final dir = Directory('${await _rootPath()}/${_safe(modelId)}');
  if (create) dir.createSync(recursive: true);
  return dir.path;
}

/// Makes [id] safe to use as a directory name.
String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

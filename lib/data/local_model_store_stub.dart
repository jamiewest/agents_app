// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Fallback implementation of the local model store for platforms with
/// neither `dart:js_interop` nor `dart:io`. Everything is a safe no-op;
/// these functions exist only so shared code can call them unconditionally.
library;

/// Whether persistent local-model storage is available on this platform.
bool get localModelPersistenceSupported => false;

/// No-op: this platform has no persistent storage for picked files.
Future<void> persistLocalModelFile({
  required String modelId,
  required String kindKey,
  required String sourcePath,
}) async {}

/// No-op: nothing is ever stored, so there is nothing to restore.
Future<String?> restoreLocalModelLocation({
  required String modelId,
  required String kindKey,
}) async => null;

/// No-op.
Future<void> deleteLocalModelFiles(String modelId, {String? kindKey}) async {}

/// No-op.
Future<void> pruneLocalModelFiles(Set<String> keepModelIds) async {}

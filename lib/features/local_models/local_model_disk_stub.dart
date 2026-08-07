// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Inert disk accounting for platforms with neither `dart:io` nor OPFS.
library;

import 'package:agents_flutter/agents_flutter.dart';

/// Whether this platform can report or reclaim local-model disk usage.
bool get localModelDiskSupported => false;

/// The directory local-model bytes live under, or null when the platform
/// has no user-visible path for it.
Future<String?> localModelStorageRootPath() async => null;

/// Bytes on disk for [model] across every store, or null when unknown.
Future<int?> localModelDiskUsage(ModelConfig model) async => null;

/// Deletes [model]'s stored bytes from every store, keeping its
/// configuration.
Future<void> deleteLocalModelBytes(ModelConfig model) async {}

/// Deletes native download directories for every model **not** in
/// [keepModelIds].
Future<void> pruneLocalModelDownloads(Set<String> keepModelIds) async {}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Full app-data reset: wipes every persistence surface so the next launch
/// behaves like a first run.
///
/// The surfaces, in wipe order:
///
/// 1. Secrets (API keys) — keyed by source id, which only exists in the
///    key/value store, so they are deleted first.
/// 2. The key/value store — sources, models, saved agents, theme, thinking,
///    and embedding settings.
/// 3. Stored local model files (Application Support on native, OPFS on web).
/// 4. The inventory database (native only — the store is not registered on
///    web).
/// 5. The record store — conversations, transcripts, channels, tasks, agent
///    files, and memory.
///
/// In-memory singletons still hold pre-reset state afterwards, so callers
/// must follow up with [restartApp].
library;

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';

import '../features/inventory/inventory_store.dart';
import 'local_model_store.dart';

export 'app_restart_stub.dart'
    if (dart.library.js_interop) 'app_restart_web.dart'
    if (dart.library.io) 'app_restart_io.dart';

/// Erases everything the app persists, leaving storage as on first launch.
Future<void> resetAppData(ServiceProvider services) async {
  final keyValue = services.getRequiredService<KeyValueStore>();
  final secrets = services.getRequiredService<SecretStore>();

  final sourceKeys = await keyValue.keys(
    prefix: ConfiguredAgentsKeys.sourcePrefix,
  );
  for (final key in sourceKeys) {
    final sourceId = key.substring(ConfiguredAgentsKeys.sourcePrefix.length);
    // Best-effort: a platform keychain rejection (e.g. a sandboxed debug
    // build without keychain entitlements) must not abort the wipe — the
    // remaining surfaces still get cleared, and an orphaned secret is
    // unreadable without its source record anyway.
    try {
      await secrets.delete(ConfiguredAgentsKeys.sourceApiKeyKey(sourceId));
    } catch (error, stackTrace) {
      developer.log(
        'Failed to delete the secret for source "$sourceId" during reset.',
        name: 'agents_app.app_reset',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  for (final key in await keyValue.keys()) {
    await keyValue.delete(key);
  }

  // An empty keep-set deletes every stored model artifact.
  await pruneLocalModelFiles(const {});

  // The inventory lives in its own SQLite file outside the record store.
  await services.getService<InventoryStore>()?.destroy();

  await services.getRequiredService<RecordStore>().clearAll();
}

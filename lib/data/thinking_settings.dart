// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

/// Per-model extended-reasoning ("thinking") preference.
///
/// Read synchronously on the chat hot path — the local llama client
/// evaluates it on every request, so toggling takes effect mid-
/// conversation. Only models whose capabilities advertise thinking get
/// the toggle in the UI.
class ThinkingSettings {
  /// Creates a [ThinkingSettings] over [keyValueStore].
  ThinkingSettings(this._keyValueStore);

  static const String _prefix = 'agents_app.thinking.';

  final KeyValueStore _keyValueStore;
  final Map<String, bool> _cache = {};

  /// Loads persisted preferences into the synchronous cache.
  Future<void> load() async {
    for (final key in await _keyValueStore.keys(prefix: _prefix)) {
      _cache[key.substring(_prefix.length)] =
          await _keyValueStore.read(key) == 'true';
    }
  }

  /// Whether thinking is enabled for the model config with [modelConfigId].
  bool enabledFor(String modelConfigId) => _cache[modelConfigId] ?? false;

  /// Persists the preference for [modelConfigId].
  Future<void> setEnabled(String modelConfigId, bool enabled) async {
    _cache[modelConfigId] = enabled;
    if (enabled) {
      await _keyValueStore.write('$_prefix$modelConfigId', 'true');
    } else {
      await _keyValueStore.delete('$_prefix$modelConfigId');
    }
  }
}

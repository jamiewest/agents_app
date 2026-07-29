// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

/// Per-agent access to the shared inventory tools.
///
/// The inventory tools read and write app-wide user data, so they are opt-in
/// per agent like the other tool capabilities. The flag cannot live in
/// [AgentAccessConfig] — that model belongs to the agents_flutter package,
/// which knows nothing about this app's inventory — so it is stored here,
/// keyed by agent id, and read synchronously when an agent is built for a
/// conversation.
class InventoryAccessSettings {
  /// Creates an [InventoryAccessSettings] over [keyValueStore].
  InventoryAccessSettings(this._keyValueStore);

  static const String _prefix = 'agents_app.inventory_access.';

  final KeyValueStore _keyValueStore;
  final Map<String, bool> _cache = {};

  /// Loads persisted preferences into the synchronous cache.
  Future<void> load() async {
    for (final key in await _keyValueStore.keys(prefix: _prefix)) {
      _cache[key.substring(_prefix.length)] =
          await _keyValueStore.read(key) == 'true';
    }
  }

  /// Whether the agent with [agentId] gets the inventory tools.
  bool enabledFor(String agentId) => _cache[agentId] ?? false;

  /// Persists the preference for [agentId].
  Future<void> setEnabled(String agentId, bool enabled) async {
    _cache[agentId] = enabled;
    if (enabled) {
      await _keyValueStore.write('$_prefix$agentId', 'true');
    } else {
      await _keyValueStore.delete('$_prefix$agentId');
    }
  }
}

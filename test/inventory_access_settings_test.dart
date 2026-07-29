// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/inventory_access_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InventoryAccessSettings', () {
    late InMemoryKeyValueStore store;
    late InventoryAccessSettings settings;

    setUp(() {
      store = InMemoryKeyValueStore();
      settings = InventoryAccessSettings(store);
    });

    test('access defaults to disabled', () {
      expect(settings.enabledFor('agent-1'), isFalse);
    });

    test('an enabled agent survives a reload', () async {
      await settings.setEnabled('agent-1', true);

      final reloaded = InventoryAccessSettings(store);
      await reloaded.load();
      expect(reloaded.enabledFor('agent-1'), isTrue);
      expect(reloaded.enabledFor('agent-2'), isFalse);
    });

    test('disabling removes the stored preference', () async {
      await settings.setEnabled('agent-1', true);
      await settings.setEnabled('agent-1', false);

      expect(settings.enabledFor('agent-1'), isFalse);
      expect(await store.keys(prefix: 'agents_app.inventory_access.'), isEmpty);
    });
  });
}

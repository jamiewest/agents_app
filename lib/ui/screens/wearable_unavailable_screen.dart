// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Shown in place of the wearable screens on platforms without BLE support
/// (the web), keeping direct URLs safe without resolving [WearableService].
class WearableUnavailableScreen extends StatelessWidget {
  /// Creates a [WearableUnavailableScreen].
  const WearableUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Wearable device')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.watch_off,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Unavailable in the browser',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'The capture wearable connects over Bluetooth, which the web '
              'version of the app cannot use. Open the app on a phone or '
              'desktop to pair and sync.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

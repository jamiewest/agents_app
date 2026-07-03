// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

/// The persisted light/dark preference.
///
/// A [ChangeNotifier] so the root app rebuilds immediately when the user
/// switches modes in Settings.
class ThemeSettings extends ChangeNotifier {
  /// Creates a [ThemeSettings] over [keyValueStore].
  ThemeSettings(this._keyValueStore);

  static const String _key = 'agents_app.settings.theme_mode';

  final KeyValueStore _keyValueStore;
  ThemeMode _mode = ThemeMode.system;

  /// The active theme mode.
  ThemeMode get mode => _mode;

  /// Loads the persisted preference.
  Future<void> load() async {
    final stored = await _keyValueStore.read(_key);
    _mode = ThemeMode.values.asNameMap()[stored] ?? ThemeMode.system;
    notifyListeners();
  }

  /// Persists and applies [mode].
  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    if (mode == ThemeMode.system) {
      await _keyValueStore.delete(_key);
    } else {
      await _keyValueStore.write(_key, mode.name);
    }
  }
}

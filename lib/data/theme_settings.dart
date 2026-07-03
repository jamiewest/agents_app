// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../ui/app_theme.dart';

/// The persisted light/dark preference and Material 3 seed color.
///
/// A [ChangeNotifier] so the root app rebuilds immediately when the user
/// switches modes or seeds in Settings.
class ThemeSettings extends ChangeNotifier {
  /// Creates a [ThemeSettings] over [keyValueStore].
  ThemeSettings(this._keyValueStore);

  static const String _modeKey = 'agents_app.settings.theme_mode';
  static const String _seedKey = 'agents_app.settings.theme_seed';

  final KeyValueStore _keyValueStore;
  ThemeMode _mode = ThemeMode.system;
  AppThemeSeed _seed = AppThemeSeed.indigo;

  /// The active theme mode.
  ThemeMode get mode => _mode;

  /// The active seed color both schemes derive from.
  AppThemeSeed get seed => _seed;

  /// Loads the persisted preferences.
  Future<void> load() async {
    final storedMode = await _keyValueStore.read(_modeKey);
    _mode = ThemeMode.values.asNameMap()[storedMode] ?? ThemeMode.system;
    final storedSeed = await _keyValueStore.read(_seedKey);
    _seed = AppThemeSeed.values.asNameMap()[storedSeed] ?? AppThemeSeed.indigo;
    notifyListeners();
  }

  /// Persists and applies [mode].
  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    if (mode == ThemeMode.system) {
      await _keyValueStore.delete(_modeKey);
    } else {
      await _keyValueStore.write(_modeKey, mode.name);
    }
  }

  /// Persists and applies [seed].
  Future<void> setSeed(AppThemeSeed seed) async {
    _seed = seed;
    notifyListeners();
    if (seed == AppThemeSeed.indigo) {
      await _keyValueStore.delete(_seedKey);
    } else {
      await _keyValueStore.write(_seedKey, seed.name);
    }
  }
}

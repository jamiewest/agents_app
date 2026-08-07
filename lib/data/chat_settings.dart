// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';

/// Persisted chat-behavior preferences.
///
/// A [ChangeNotifier] so Settings reflects changes immediately. The values
/// are read live by the features they gate — the title summarizer's client
/// callback consults [autoTitleEnabled] on every pass — so a change applies
/// without restarting anything.
class ChatSettings extends ChangeNotifier {
  /// Creates a [ChatSettings] over [keyValueStore].
  ChatSettings(this._keyValueStore);

  static const String _autoTitleKey = 'agents_app.settings.auto_title';

  final KeyValueStore _keyValueStore;
  bool _autoTitleEnabled = true;

  /// Whether the background summarizer may write conversation titles.
  ///
  /// On by default. Off, conversations keep the title derived from their
  /// first message (or one set by hand).
  bool get autoTitleEnabled => _autoTitleEnabled;

  /// Loads the persisted preferences.
  Future<void> load() async {
    _autoTitleEnabled = await _keyValueStore.read(_autoTitleKey) != 'false';
    notifyListeners();
  }

  /// Persists and applies [enabled].
  Future<void> setAutoTitleEnabled(bool enabled) async {
    _autoTitleEnabled = enabled;
    notifyListeners();
    if (enabled) {
      await _keyValueStore.delete(_autoTitleKey);
    } else {
      await _keyValueStore.write(_autoTitleKey, 'false');
    }
  }
}

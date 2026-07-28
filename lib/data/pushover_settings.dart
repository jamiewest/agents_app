// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';

/// The persisted Pushover credentials and the client built from them.
///
/// Pushover tools send real notifications to a real person, so the
/// application token and user key live in the [SecretStore] beside the model
/// API keys, never in the plain key/value store. Agents receive the tools
/// only while [client] is non-null; the recipient is fixed by this
/// configuration and is never chosen by the model.
///
/// A [ChangeNotifier] so Settings reflects saves immediately. Agents pick up
/// a credential change the next time one is built for a conversation.
class PushoverSettings extends ChangeNotifier {
  /// Creates a [PushoverSettings] over [secrets].
  PushoverSettings(this._secrets);

  /// The secret key holding the Pushover application token.
  static const String tokenSecretKey = 'agents_app.pushover.token';

  /// The secret key holding the recipient's user (or group) key.
  static const String userSecretKey = 'agents_app.pushover.user';

  final SecretStore _secrets;
  PushoverClient? _client;

  /// The client for the stored credentials, or `null` while unconfigured.
  PushoverClient? get client => _client;

  /// Whether both credentials are stored.
  bool get isConfigured => _client != null;

  /// Loads the stored credentials and rebuilds [client].
  ///
  /// Runs during app bootstrap, so a platform keychain rejection (e.g. a
  /// sandboxed debug build without keychain entitlements) leaves Pushover
  /// unconfigured instead of aborting startup.
  Future<void> load() async {
    String token;
    String user;
    try {
      token = (await _secrets.read(tokenSecretKey))?.trim() ?? '';
      user = (await _secrets.read(userSecretKey))?.trim() ?? '';
    } catch (error, stackTrace) {
      developer.log(
        'Failed to read the Pushover credentials.',
        name: 'agents_app.pushover_settings',
        error: error,
        stackTrace: stackTrace,
      );
      token = '';
      user = '';
    }
    _client = token.isEmpty || user.isEmpty
        ? null
        : PushoverClient(token: token, user: user);
    notifyListeners();
  }

  /// Persists [token] and [user] and rebuilds [client].
  ///
  /// Throws [ArgumentError] when either value is blank; use [clear] to
  /// remove the configuration instead.
  Future<void> save({required String token, required String user}) async {
    final trimmedToken = token.trim();
    final trimmedUser = user.trim();
    if (trimmedToken.isEmpty || trimmedUser.isEmpty) {
      throw ArgumentError(
        'Both an application token and a user key are required.',
      );
    }
    await _secrets.write(tokenSecretKey, trimmedToken);
    await _secrets.write(userSecretKey, trimmedUser);
    _client = PushoverClient(token: trimmedToken, user: trimmedUser);
    notifyListeners();
  }

  /// Deletes the stored credentials and drops [client].
  Future<void> clear() async {
    await _secrets.delete(tokenSecretKey);
    await _secrets.delete(userSecretKey);
    _client = null;
    notifyListeners();
  }

  /// Reads the stored application token, for prefilling the Settings form.
  Future<String> storedToken() async =>
      (await _secrets.read(tokenSecretKey))?.trim() ?? '';

  /// Reads the stored user key, for prefilling the Settings form.
  Future<String> storedUser() async =>
      (await _secrets.read(userSecretKey))?.trim() ?? '';
}

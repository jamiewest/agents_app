// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The macOS secret store: the data protection keychain, reading through to
/// the legacy login keychain once per key.
///
/// `agents_flutter` defaults macOS to the legacy file-based keychain, because
/// the data protection keychain needs a `keychain-access-groups` entitlement
/// and a real signing identity, which an ad-hoc signed app does not have.
/// This app has both (see `macos/Runner/*.entitlements` and the Runner
/// target's `DEVELOPMENT_TEAM`), so it opts back in — the legacy keychain
/// guards every item with an ACL bound to the calling binary's code
/// signature, and macOS asks for the login password whenever the signature it
/// recorded no longer matches. A debug build gets a fresh signature on every
/// rebuild, so that prompt came back for every secret, every launch.
///
/// Data protection keychain items carry no ACL: access is decided by the
/// access group in the entitlement, which is stable across rebuilds. They are
/// also scoped to this app rather than shared with every other
/// `flutter_secure_storage` app on the machine, which the login keychain's
/// single `flutter_secure_storage_service` service name is not.
///
/// [read] falls back to the legacy keychain so secrets written before the
/// switch — API keys, Pushover credentials, the Tor onion service key — are
/// not lost, and moves each one across the first time it is read. Migrating
/// per key rather than in bulk is deliberate: a bulk `readAll` would sweep up
/// the login keychain entries belonging to other apps.
///
/// Once no login keychain entries are left, this class can collapse back to a
/// plain `FlutterSecureSecretStore`.
class MacKeychainSecretStore extends SecretStore {
  /// Creates a store, optionally over preconfigured [store] and [legacy]
  /// backings.
  MacKeychainSecretStore({SecretStore? store, SecretStore? legacy})
    : _store = store ?? FlutterSecureSecretStore(storage: _dataProtection),
      _legacy = legacy ?? FlutterSecureSecretStore(storage: _login);

  static const _dataProtection = FlutterSecureStorage();

  static const _login = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  final SecretStore _store;
  final SecretStore _legacy;

  @override
  Future<String?> read(String key) async {
    final value = await _store.read(key);
    if (value != null) {
      return value;
    }
    final legacy = await _legacy.read(key);
    if (legacy == null) {
      return null;
    }
    await _store.write(key, legacy);
    // Read back before dropping the other copy. A write that reports success
    // without persisting would otherwise leave nothing at all behind, and for
    // the onion service key that is unrecoverable: the address is derived from
    // it, so every paired peer breaks with no way to get it back.
    if (await _store.read(key) != legacy) {
      developer.log(
        'Kept the legacy keychain entry for "$key": the migrated copy did not '
        'read back.',
        name: 'agents_app.mac_keychain_secret_store',
      );
      return legacy;
    }
    // A failed cleanup from here only leaves an unread entry behind, since
    // every later read is served by the store above.
    await _deleteLegacy(key);
    return legacy;
  }

  @override
  Future<void> write(String key, String value) => _store.write(key, value);

  @override
  Future<void> delete(String key) async {
    await _store.delete(key);
    await _deleteLegacy(key);
  }

  Future<void> _deleteLegacy(String key) async {
    try {
      await _legacy.delete(key);
    } catch (error, stackTrace) {
      developer.log(
        'Failed to remove the legacy keychain entry for "$key".',
        name: 'agents_app.mac_keychain_secret_store',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// The macOS override for `useConfiguredAgents(secretStore: ...)`, or `null`
/// on the platforms where the package default already does the right thing.
SecretStore Function(ServiceProvider services)? get macKeychainSecretStore =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
    ? (services) => MacKeychainSecretStore()
    : null;

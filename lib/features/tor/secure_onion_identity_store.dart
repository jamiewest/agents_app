// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:tor_flutter/tor_flutter.dart';

/// Persists onion service keys in the platform keychain.
///
/// The onion address is derived from the service key, so this is what makes an
/// address stable across launches — and the address is what users share, so
/// losing the key means every paired peer has to pair again.
///
/// The store cannot live in the agents_flutter package: that package is
/// published and knows nothing about Tor, so an unpublished `tor_flutter`
/// dependency cannot go there. It sits here instead, the same way
/// [InventoryAccessSettings] holds app-local per-agent state, and is wired in
/// the composition root.
///
/// Storage is split by sensitivity:
///
/// * [SecretStore] holds the authoritative record — key **and** address — so
///   the two can never disagree.
/// * [KeyValueStore] holds an index of ids to their addresses. It exists only
///   because `SecretStore` cannot enumerate, and because the sharing UI can
///   then show an address without touching the keychain.
///
/// The index is rebuildable; the secret is not.
class SecureOnionIdentityStore implements OnionIdentityStore {
  /// Creates a [SecureOnionIdentityStore] over the app's stores.
  SecureOnionIdentityStore(this._secretStore, this._keyValueStore);

  /// Creates a [SecureOnionIdentityStore] from a service provider.
  factory SecureOnionIdentityStore.fromServices(ServiceProvider services) =>
      SecureOnionIdentityStore(
        services.getRequiredService<SecretStore>(),
        services.getRequiredService<KeyValueStore>(),
      );

  static const String _prefix = 'agents_app.tor.identity.';

  final SecretStore _secretStore;
  final KeyValueStore _keyValueStore;

  @override
  Future<OnionIdentityRecord?> read(String id) async {
    final raw = await _secretStore.read(_key(id));
    if (raw == null) {
      // The index knowing about an identity whose key is gone means the key
      // was lost, not that the identity never existed. Reporting absence here
      // would let a new key be generated under the same id, silently changing
      // the address. Rotation has to be a deliberate act.
      if (await _keyValueStore.read(_key(id)) != null) {
        throw OnionIdentityUnrecoverableError(
          id,
          reason: 'the keychain entry is missing but the index still lists it',
        );
      }
      return null;
    }

    final OnionIdentityRecord record;
    try {
      record = _decode(id, raw);
    } on FormatException catch (error) {
      throw OnionIdentityUnrecoverableError(
        id,
        reason: 'the stored key is corrupt (${error.message})',
      );
    }

    // The secret is authoritative, so a missing or stale index entry is just
    // drift and can be repaired without touching the key.
    if (await _keyValueStore.read(_key(id)) != record.address) {
      await _keyValueStore.write(_key(id), record.address);
    }
    return record;
  }

  @override
  Future<void> write(OnionIdentityRecord record) async {
    await _secretStore.write(_key(record.id), _encode(record));
    await _keyValueStore.write(_key(record.id), record.address);
  }

  @override
  Future<void> delete(String id) async {
    // Secret first: a crash between the two leaves an orphaned index entry,
    // which [read] reports as unrecoverable. The reverse order would leave an
    // unreachable key and let a new one be generated silently.
    await _secretStore.delete(_key(id));
    await _keyValueStore.delete(_key(id));
  }

  @override
  Future<List<String>> list() async {
    final keys = await _keyValueStore.keys(prefix: _prefix);
    return keys.map((key) => key.substring(_prefix.length)).toList();
  }

  static String _key(String id) => '$_prefix$id';

  static String _encode(OnionIdentityRecord record) => jsonEncode({
    'address': record.address,
    'key': base64Encode(record.secretKey),
  });

  static OnionIdentityRecord _decode(String id, String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected a JSON object');
    }
    final address = decoded['address'];
    final key = decoded['key'];
    if (address is! String || address.isEmpty || key is! String) {
      throw const FormatException('missing address or key');
    }
    return OnionIdentityRecord(
      id: id,
      address: address,
      secretKey: Uint8List.fromList(base64Decode(key)),
    );
  }
}

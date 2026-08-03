// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:agents_app/features/tor/secure_onion_identity_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_flutter/tor_flutter.dart';

void main() {
  late InMemorySecretStore secrets;
  late InMemoryKeyValueStore keyValues;
  late SecureOnionIdentityStore store;

  const prefix = 'agents_app.tor.identity.';

  OnionIdentityRecord recordFor(String id, {String address = 'abc.onion'}) =>
      OnionIdentityRecord(
        id: id,
        address: address,
        secretKey: Uint8List.fromList(List.generate(64, (i) => i)),
      );

  setUp(() {
    secrets = InMemorySecretStore();
    keyValues = InMemoryKeyValueStore();
    store = SecureOnionIdentityStore(secrets, keyValues);
  });

  group('round trip', () {
    test('reads back what was written', () async {
      final written = recordFor('default');
      await store.write(written);

      final read = await store.read('default');

      expect(read, isNotNull);
      expect(read!.address, written.address);
      expect(read.secretKey, written.secretKey);
    });

    test('returns null for an unknown identity', () async {
      expect(await store.read('missing'), isNull);
    });

    test('keeps identities separate', () async {
      await store.write(recordFor('primary', address: 'one.onion'));
      await store.write(recordFor('disposable', address: 'two.onion'));

      expect((await store.read('primary'))!.address, 'one.onion');
      expect((await store.read('disposable'))!.address, 'two.onion');
    });

    test('lists stored identity ids', () async {
      await store.write(recordFor('primary'));
      await store.write(recordFor('disposable'));

      expect(await store.list(), unorderedEquals(['primary', 'disposable']));
    });

    test('delete removes both the key and the index entry', () async {
      await store.write(recordFor('default'));
      await store.delete('default');

      expect(await store.read('default'), isNull);
      expect(await store.list(), isEmpty);
    });
  });

  group('storage separation', () {
    test('key material goes only to the secret store', () async {
      await store.write(recordFor('default'));

      final indexed = await keyValues.read('${prefix}default');
      expect(indexed, 'abc.onion');
      expect(indexed, isNot(contains('AAEC')));

      final secret = await secrets.read('${prefix}default');
      expect(secret, contains('key'));
    });
  });

  group('unrecoverable keys', () {
    test('throws when the index survives but the key is gone', () async {
      await store.write(recordFor('default'));
      // Models a keychain wipe that leaves ordinary preferences intact.
      await secrets.delete('${prefix}default');

      await expectLater(
        store.read('default'),
        throwsA(isA<OnionIdentityUnrecoverableError>()),
      );
    });

    test('throws rather than silently reissuing on corrupt data', () async {
      await keyValues.write('${prefix}default', 'abc.onion');
      await secrets.write('${prefix}default', 'not json at all');

      await expectLater(
        store.read('default'),
        throwsA(isA<OnionIdentityUnrecoverableError>()),
      );
    });

    test('throws when the stored record is missing its address', () async {
      await keyValues.write('${prefix}default', 'abc.onion');
      await secrets.write('${prefix}default', jsonEncode({'key': 'AAEC'}));

      await expectLater(
        store.read('default'),
        throwsA(isA<OnionIdentityUnrecoverableError>()),
      );
    });

    test('delete clears an unrecoverable identity', () async {
      await store.write(recordFor('default'));
      await secrets.delete('${prefix}default');

      // The escape hatch the app offers: it is the orphaned index entry that
      // makes read throw, so removing it is what lets a new key be minted.
      await store.delete('default');

      expect(await store.read('default'), isNull);
      expect(await store.list(), isEmpty);
    });

    test('a deleted identity reads as absent, not unrecoverable', () async {
      await store.write(recordFor('default'));
      await store.delete('default');

      expect(await store.read('default'), isNull);
    });
  });

  group('index repair', () {
    test('rebuilds a missing index entry from the secret', () async {
      await store.write(recordFor('default'));
      // Models preferences being cleared while the keychain survives, which is
      // the normal state after an iOS reinstall.
      await keyValues.delete('${prefix}default');

      final read = await store.read('default');

      expect(read, isNotNull);
      expect(read!.address, 'abc.onion');
      expect(await keyValues.read('${prefix}default'), 'abc.onion');
      expect(await store.list(), ['default']);
    });

    test('corrects a stale index entry', () async {
      await store.write(recordFor('default', address: 'real.onion'));
      await keyValues.write('${prefix}default', 'stale.onion');

      final read = await store.read('default');

      expect(read!.address, 'real.onion');
      expect(await keyValues.read('${prefix}default'), 'real.onion');
    });
  });

  group('address stability', () {
    test('survives a store rebuilt over the same backends', () async {
      await store.write(recordFor('default', address: 'stable.onion'));

      // A fresh store over the same persistence, as on app restart.
      final restarted = SecureOnionIdentityStore(secrets, keyValues);

      expect((await restarted.read('default'))!.address, 'stable.onion');
    });
  });
}

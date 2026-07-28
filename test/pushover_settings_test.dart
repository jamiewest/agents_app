// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/pushover_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// A secret store whose reads always fail, like a sandboxed build without
/// keychain entitlements.
class _ThrowingSecretStore extends SecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keychain');

  @override
  Future<void> delete(String key) async => throw StateError('no keychain');
}

void main() {
  test('starts unconfigured and loads as unconfigured when empty', () async {
    final settings = PushoverSettings(InMemorySecretStore());
    expect(settings.isConfigured, isFalse);
    await settings.load();
    expect(settings.isConfigured, isFalse);
    expect(settings.client, isNull);
  });

  test('save builds a client and persists trimmed credentials', () async {
    final secrets = InMemorySecretStore();
    final settings = PushoverSettings(secrets);
    await settings.save(token: '  app-token  ', user: '  user-key  ');

    expect(settings.isConfigured, isTrue);
    expect(settings.client?.token, 'app-token');
    expect(settings.client?.user, 'user-key');
    expect(await secrets.read(PushoverSettings.tokenSecretKey), 'app-token');
    expect(await secrets.read(PushoverSettings.userSecretKey), 'user-key');
  });

  test('load rebuilds the client from stored credentials', () async {
    final secrets = InMemorySecretStore();
    await secrets.write(PushoverSettings.tokenSecretKey, 'app-token');
    await secrets.write(PushoverSettings.userSecretKey, 'user-key');

    final settings = PushoverSettings(secrets);
    await settings.load();
    expect(settings.client?.token, 'app-token');
    expect(settings.client?.user, 'user-key');
  });

  test('load treats a lone credential as unconfigured', () async {
    final secrets = InMemorySecretStore();
    await secrets.write(PushoverSettings.tokenSecretKey, 'app-token');

    final settings = PushoverSettings(secrets);
    await settings.load();
    expect(settings.client, isNull);
  });

  test('save rejects blank values', () async {
    final settings = PushoverSettings(InMemorySecretStore());
    await expectLater(
      settings.save(token: '', user: 'user-key'),
      throwsArgumentError,
    );
    await expectLater(
      settings.save(token: 'app-token', user: '   '),
      throwsArgumentError,
    );
    expect(settings.isConfigured, isFalse);
  });

  test('clear deletes stored credentials and drops the client', () async {
    final secrets = InMemorySecretStore();
    final settings = PushoverSettings(secrets);
    await settings.save(token: 'app-token', user: 'user-key');

    await settings.clear();
    expect(settings.client, isNull);
    expect(await secrets.read(PushoverSettings.tokenSecretKey), isNull);
    expect(await secrets.read(PushoverSettings.userSecretKey), isNull);
  });

  test('load survives a failing secret store', () async {
    final settings = PushoverSettings(_ThrowingSecretStore());
    await settings.load();
    expect(settings.client, isNull);
  });

  test('notifies listeners on save, clear, and load', () async {
    final settings = PushoverSettings(InMemorySecretStore());
    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.save(token: 'app-token', user: 'user-key');
    await settings.clear();
    await settings.load();
    expect(notifications, 3);
  });
}

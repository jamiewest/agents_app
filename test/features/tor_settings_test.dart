// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/features/tor/secure_onion_identity_store.dart';
import 'package:agents_app/features/tor/tor_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_flutter/tor_flutter.dart';
import 'package:tor_flutter/tor_flutter_testing.dart';

void main() {
  late InMemoryKeyValueStore kv;
  late FakeTorPlatform platform;
  late TorRuntime runtime;
  late TorSettings settings;

  TorSettings build({FakeTorPlatform? backend}) {
    platform = backend ?? FakeTorPlatform();
    runtime = PlatformTorRuntime(
      platform: platform,
      identityStore: SecureOnionIdentityStore(InMemorySecretStore(), kv),
      options: TorOptions(),
    );
    final created = TorSettings(
      kv,
      runtime,
      startTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      created.dispose();
      await platform.dispose();
    });
    return created;
  }

  setUp(() {
    kv = InMemoryKeyValueStore();
    settings = build();
  });

  group('switching Tor on', () {
    test('starts the runtime without anything being shared', () async {
      // The whole point of this setting: a device that only ever dials a peer
      // needs Tor running, but has no reason to publish an address of its own.
      await settings.setEnabled(true);

      expect(settings.enabled, isTrue);
      expect(settings.isReady, isTrue);
      expect(runtime.publishedServices, isEmpty);
    });

    test('exposes a usable SOCKS port once ready', () async {
      await settings.setEnabled(true);

      final status = runtime.status;
      expect(status, isA<TorReady>());
      expect((status as TorReady).socksPort, greaterThan(0));
    });

    test('switching off stops the runtime', () async {
      await settings.setEnabled(true);
      await settings.setEnabled(false);

      expect(settings.enabled, isFalse);
      expect(runtime.status, isA<TorStopped>());
    });

    test('is remembered across a restart', () async {
      await settings.setEnabled(true);

      final relaunched = build();
      await relaunched.load();
      // load() starts in the background so the first frame is not held up,
      // so wait on the runtime rather than assuming it is already up.
      await runtime.statusChanges
          .firstWhere((status) => status is TorReady)
          .timeout(const Duration(seconds: 10));

      expect(relaunched.enabled, isTrue);
      expect(relaunched.isReady, isTrue);
    });
  });

  group('when Tor cannot start', () {
    test('releases the switch instead of wedging', () async {
      final failing = build(
        backend: FakeTorPlatform(failBootstrapWith: 'no network'),
      );

      await failing
          .setEnabled(true)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('setEnabled never returned'),
          );

      expect(failing.busy, isFalse);
      expect(failing.enabled, isFalse);
      expect(failing.error, isNotNull);
    });

    test('gives up on a wedged backend', () async {
      final stalled = build(backend: FakeTorPlatform(stallBootstrap: true));

      await stalled
          .setEnabled(true)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('setEnabled never returned'),
          );

      expect(stalled.enabled, isFalse);
      expect(stalled.error, contains('did not finish starting'));
    });

    test('a failed start is not remembered as on', () async {
      final failing = build(
        backend: FakeTorPlatform(failBootstrapWith: 'no network'),
      );
      await failing.setEnabled(true).timeout(const Duration(seconds: 10));

      final relaunched = build();
      await relaunched.load();

      expect(relaunched.enabled, isFalse);
    });

    test('names clock skew rather than reporting a network fault', () async {
      final skewed = build(
        backend: FakeTorPlatform(
          failBootstrapWith: 'bad time',
          bootstrapClockSkew: true,
        ),
      );

      await skewed.setEnabled(true).timeout(const Duration(seconds: 10));

      expect(skewed.error, contains('clock'));
    });
  });
}

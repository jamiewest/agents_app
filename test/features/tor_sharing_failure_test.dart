// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart' show InMemoryAgentFileStore;
import 'package:agents_app/features/tor/secure_onion_identity_store.dart';
import 'package:agents_app/features/tor/tor_sharing_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_flutter/tor_flutter.dart';
import 'package:tor_flutter/tor_flutter_testing.dart';

const _localSource = ModelSourceConfig(
  id: 's-local',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);
const _localModel = ModelConfig(
  id: 'm-local',
  sourceId: 's-local',
  modelId: 'fake-model',
);
const _helper = SavedAgentConfig(
  id: 'a-helper',
  name: 'Helper',
  modelId: 'm-local',
  description: 'Answers questions.',
);

ServiceProvider _buildServices(InMemoryKeyValueStore kv) =>
    (ServiceCollection()
          ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
          ..addConfiguredAgents(
            keyValueStore: (_) => kv,
            secretStore: (_) => InMemorySecretStore(),
            chatClientFactory: (_) => ConfiguredChatClientFactory(
              customClientResolver:
                  ({required source, required model, httpClient, scope}) =>
                      _EchoChatClient(),
            ),
            configureHarness: (options) => options
              ..disableAgentSkillsProvider = true
              ..fileMemoryStore = InMemoryAgentFileStore()
              ..fileAccessStore = InMemoryAgentFileStore()
              ..enableConnectivity = false
              ..enableTemporal = false
              ..enableAppInfo = false
              ..enableDeviceInfo = false,
          ))
        .buildServiceProvider();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Hosting is macOS-only (see TorSharingSettings.isSupported), and the test
  // binding reports Android unless told otherwise — so every case here is a
  // Mac.
  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => 'wifi',
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success('wifi'),
      ),
    );
  });

  group('when Tor cannot start', () {
    late InMemoryKeyValueStore kv;
    late NetworkSharingSettings network;

    /// Sharing over a backend that fails or stalls instead of coming up.
    TorSharingSettings sharingOver(
      FakeTorPlatform platform, {
      Duration bootstrapTimeout = const Duration(seconds: 90),
    }) {
      final identities = SecureOnionIdentityStore(InMemorySecretStore(), kv);
      final sharing = TorSharingSettings(
        kv,
        PlatformTorRuntime(
          platform: platform,
          identityStore: identities,
          options: TorOptions(),
        ),
        network,
        identities,
        bootstrapTimeout: bootstrapTimeout,
      );
      addTearDown(() async {
        sharing.dispose();
        await platform.dispose();
      });
      return sharing;
    }

    setUp(() async {
      kv = InMemoryKeyValueStore();
      final services = _buildServices(kv);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_localSource);
      await manager.saveModel(_localModel);
      await manager.saveAgent(_helper);
      network = NetworkSharingSettings(services);
      await network.setShared(_helper.id, true);
    });

    tearDown(() async {
      await network.setShared(_helper.id, false);
      network.dispose();
    });

    test('a failed bootstrap releases the switch instead of wedging', () async {
      final sharing = sharingOver(
        FakeTorPlatform(failBootstrapWith: 'no network'),
      );

      // The status stream stays open after a failure, so waiting only for
      // readiness would never return and leave the switch stuck on "busy".
      await sharing
          .setEnabled(true)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('setEnabled never returned'),
          );

      expect(sharing.busy, isFalse);
      expect(sharing.enabled, isFalse);
      expect(sharing.isPublished, isFalse);
      expect(sharing.error, isNotNull);
    });

    test('a wedged backend gives up on the bootstrap timeout', () async {
      final sharing = sharingOver(
        FakeTorPlatform(stallBootstrap: true),
        bootstrapTimeout: const Duration(milliseconds: 200),
      );

      await sharing
          .setEnabled(true)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('setEnabled never returned'),
          );

      expect(sharing.busy, isFalse);
      expect(sharing.enabled, isFalse);
      expect(sharing.error, contains('did not finish starting'));
    });

    test('a failed start is not remembered as on', () async {
      final sharing = sharingOver(
        FakeTorPlatform(failBootstrapWith: 'no network'),
      );
      await sharing.setEnabled(true).timeout(const Duration(seconds: 5));

      // A relaunch must not retry a start that already failed, so the
      // persisted flag has to record what happened, not what was asked for.
      final relaunched = sharingOver(FakeTorPlatform());
      await relaunched.load();

      expect(relaunched.enabled, isFalse);
    });

    test('clock skew is reported as its own failure', () async {
      final sharing = sharingOver(
        FakeTorPlatform(
          failBootstrapWith: 'bad time',
          bootstrapClockSkew: true,
        ),
      );

      await sharing.setEnabled(true).timeout(const Duration(seconds: 5));

      // A wrong clock reads as a network fault and sends people looking in
      // entirely the wrong place, so it has to be named.
      expect(sharing.error, contains('clock'));
    });

    test('sharing stays on the LAN when Tor never came up', () async {
      final sharing = sharingOver(
        FakeTorPlatform(failBootstrapWith: 'no network'),
      );
      await sharing.setEnabled(true).timeout(const Duration(seconds: 5));

      // The host must not be left bound to loopback after a failed switch,
      // which would silently drop LAN sharing that was working before.
      expect(network.loopbackOnly, isFalse);
      expect(network.isRunning, isTrue);
    });
  });

  group('when the identity key is lost', () {
    const enabledKey = 'agents_app.tor.sharing.enabled';
    const secretKey =
        'agents_app.tor.identity.${TorSharingSettings.identityId}';

    late InMemoryKeyValueStore kv;
    late InMemorySecretStore secrets;
    late SecureOnionIdentityStore identities;
    late NetworkSharingSettings network;
    late FakeTorPlatform platform;

    /// Sharing over a keychain that lost the key while preferences survived —
    /// the state a keychain wipe or a restore onto a new device leaves behind.
    TorSharingSettings wedged({OnionIdentityStore? store}) {
      final sharing = TorSharingSettings(
        kv,
        PlatformTorRuntime(
          platform: platform,
          identityStore: identities,
          options: TorOptions(),
        ),
        network,
        store ?? identities,
      );
      addTearDown(sharing.dispose);
      return sharing;
    }

    setUp(() async {
      kv = InMemoryKeyValueStore();
      secrets = InMemorySecretStore();
      identities = SecureOnionIdentityStore(secrets, kv);
      platform = FakeTorPlatform();
      final services = _buildServices(kv);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_localSource);
      await manager.saveModel(_localModel);
      await manager.saveAgent(_helper);
      network = NetworkSharingSettings(services);
      await network.setShared(_helper.id, true);

      await identities.write(
        OnionIdentityRecord(
          id: TorSharingSettings.identityId,
          address: 'oldaddress.onion',
          secretKey: Uint8List.fromList(List.generate(64, (i) => i)),
        ),
      );
      await secrets.delete(secretKey);
      // Sharing was on when the key went missing, which is how a user arrives
      // here: it worked yesterday.
      await kv.write(enabledKey, 'true');
    });

    tearDown(() async {
      await network.setShared(_helper.id, false);
      network.dispose();
      await platform.dispose();
    });

    test('a launch says so instead of retrying forever', () async {
      final sharing = wedged();
      await sharing.load();

      expect(sharing.isIdentityUnrecoverable, isTrue);
      expect(sharing.error, contains('could not be read'));
      // Left remembered as on, every launch would spend a full bootstrap
      // arriving at a failure already known here.
      expect(sharing.enabled, isFalse);
      expect(await kv.read(enabledKey), 'false');
    });

    test('the switch refuses rather than bouncing back off', () async {
      final sharing = wedged();
      await sharing.load();

      await sharing.setEnabled(true).timeout(const Duration(seconds: 5));

      expect(sharing.enabled, isFalse);
      // The state the user has to act on has to survive touching the switch;
      // _apply clears the message on entry.
      expect(sharing.isIdentityUnrecoverable, isTrue);
      expect(sharing.error, isNotNull);
    });

    test('resetting the identity clears the wedge', () async {
      final sharing = wedged();
      await sharing.load();

      await sharing.resetIdentity();

      expect(sharing.isIdentityUnrecoverable, isFalse);
      expect(sharing.error, isNull);
      // The old address is gone for good; showing it would suggest it still
      // meant something.
      expect(sharing.address, isNull);
    });

    test('a fresh address is minted on the next publish', () async {
      final sharing = wedged();
      await sharing.load();
      await sharing.resetIdentity();

      await sharing.setEnabled(true).timeout(const Duration(seconds: 10));
      addTearDown(() => sharing.setEnabled(false));

      expect(sharing.enabled, isTrue);
      expect(sharing.address, isNotNull);
      expect(sharing.address, isNot('oldaddress.onion'));
      expect(sharing.isPublished, isTrue);
    });

    test('a reset is not deliberate enough to be automatic', () async {
      final sharing = wedged();
      await sharing.load();
      await sharing.resetIdentity();

      // Publishing waits for the user to switch sharing on again, so nobody
      // is handed a new address to share as a side effect of a repair.
      expect(sharing.enabled, isFalse);
      expect(sharing.isPublished, isFalse);
      expect(await identities.read(TorSharingSettings.identityId), isNull);
    });

    test('a reset that fails keeps itself on offer', () async {
      final sharing = wedged(store: _UndeletableIdentityStore(identities));
      await sharing.load();

      await sharing.resetIdentity();

      // Reporting success here would present a still-wedged app as repaired
      // and hide the only control that can fix it.
      expect(sharing.isIdentityUnrecoverable, isTrue);
      expect(sharing.error, contains('Could not reset'));
      expect(sharing.busy, isFalse);
    });
  });
}

/// An identity store whose keys cannot be removed, as when the keychain
/// refuses the delete.
class _UndeletableIdentityStore implements OnionIdentityStore {
  _UndeletableIdentityStore(this._inner);

  final OnionIdentityStore _inner;

  @override
  Future<void> delete(String id) async =>
      throw StateError('keychain delete rejected');

  @override
  Future<OnionIdentityRecord?> read(String id) => _inner.read(id);

  @override
  Future<void> write(OnionIdentityRecord record) => _inner.write(record);

  @override
  Future<List<String>> list() => _inner.list();
}

final class _EchoChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(
    messages: <ai.ChatMessage>[
      ai.ChatMessage.fromText(ai.ChatRole.assistant, 'ok'),
    ],
  );

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => Stream<ai.ChatResponseUpdate>.value(
    ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok'),
  );

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

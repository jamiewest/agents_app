// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

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

  group('sharing agents over an onion address', () {
    late InMemoryKeyValueStore kv;
    late InMemorySecretStore secrets;
    late ServiceProvider services;
    late NetworkSharingSettings network;
    late FakeTorPlatform platform;
    late SecureOnionIdentityStore identities;
    late TorRuntime runtime;
    late TorSharingSettings sharing;

    setUp(() async {
      kv = InMemoryKeyValueStore();
      secrets = InMemorySecretStore();
      services = _buildServices(kv);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_localSource);
      await manager.saveModel(_localModel);
      await manager.saveAgent(_helper);

      network = NetworkSharingSettings(services);
      // Starts the host, exactly as toggling sharing on an agent's page does.
      await network.setShared(_helper.id, true);

      platform = FakeTorPlatform();
      identities = SecureOnionIdentityStore(secrets, kv);
      runtime = PlatformTorRuntime(
        platform: platform,
        identityStore: identities,
        options: TorOptions(),
      );
      sharing = TorSharingSettings(kv, runtime, network, identities);

      // Installed before any client is built: package:http and package:oxy
      // both capture an HttpClient on construction.
      HttpOverrides.global = TorHttpOverrides(runtime);
    });

    tearDown(() async {
      HttpOverrides.global = null;
      sharing.dispose();
      await network.setShared(_helper.id, false);
      network.dispose();
      await platform.dispose();
    });

    test('a peer pairs and lists agents entirely over the onion', () async {
      await sharing.setEnabled(true);

      final offer = await sharing.createPairingOffer();
      expect(offer.host, endsWith('.onion'));
      expect(offer.baseUrl, startsWith('http://'));

      final client = PairingClient();
      final result = await client.pair(
        offer,
        clientName: 'phone',
        clientId: 'client-1',
      );

      expect(result.deviceName, isNotEmpty);
      expect(result.credential, isNotEmpty);

      final agents = await client.listAgents(offer.baseUrl, result.credential);
      expect(agents.single.name, 'Helper');
      expect(agents.single.path, '/agents/helper');

      // Every hop went through the proxy as a hostname, so nothing resolved
      // the address locally.
      expect(platform.connectRequests, isNotEmpty);
      expect(platform.connectRequests.every((h) => h == offer.host), isTrue);
    });

    test(
      'the host is not reachable on the LAN while sharing over Tor',
      () async {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        final lan = interfaces
            .expand((interface) => interface.addresses)
            .where((address) => !address.isLoopback)
            .firstOrNull;
        if (lan == null) return; // No LAN interface on this machine.

        await sharing.setEnabled(true);
        final port = network.port!;

        // Every A2A host defaults to the same port, so a sibling test file
        // serving on the network could answer here and look like a leak from
        // this one. Only assert when nothing else holds the port.
        Socket? foreign;
        try {
          foreign = await Socket.connect(
            lan,
            port,
            timeout: const Duration(seconds: 2),
          );
        } on SocketException {
          // Nothing there, which is what this test wants to prove.
        }
        if (foreign != null) {
          foreign.destroy();
          return;
        }

        await expectLater(
          Socket.connect(lan, port, timeout: const Duration(seconds: 2)),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test('the shared address survives turning sharing off and on', () async {
      await sharing.setEnabled(true);
      final first = sharing.address;
      expect(first, isNotNull);

      await sharing.setEnabled(false);
      // Kept while off, because the identity still exists and the user has
      // already handed this address out.
      expect(sharing.address, first);

      await sharing.setEnabled(true);
      expect(sharing.address, first);
    });

    test('the address survives a full restart of the runtime', () async {
      await sharing.setEnabled(true);
      final before = sharing.address;

      await sharing.setEnabled(false);
      await runtime.stop();

      // A fresh runtime over the same identity store, as on app relaunch.
      final restored = SecureOnionIdentityStore(secrets, kv);
      final restarted = PlatformTorRuntime(
        platform: platform,
        identityStore: restored,
        options: TorOptions(),
      );
      final resumed = TorSharingSettings(kv, restarted, network, restored);
      addTearDown(resumed.dispose);

      await resumed.load();
      expect(resumed.address, before, reason: 'address read back before start');

      await resumed.setEnabled(true);
      expect(resumed.address, before);
    });

    test('a pairing offer is refused before anything is published', () async {
      await expectLater(
        sharing.createPairingOffer(),
        throwsA(isA<StateError>()),
      );
    });

    test('an offer created over Tor never advertises a LAN address', () async {
      await sharing.setEnabled(true);
      final torOffer = await sharing.createPairingOffer();
      final lanOffer = await network.createPairingOffer();

      expect(torOffer.host, endsWith('.onion'));
      expect(lanOffer.host, isNot(endsWith('.onion')));
      expect(torOffer.port, 80);
    });
  });
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

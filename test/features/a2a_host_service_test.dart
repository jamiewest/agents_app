import 'dart:io';

import 'package:agents/agents.dart' show InMemoryAgentFileStore;
import 'package:agents_app/features/network/a2a_host_service.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
                  ({required source, required model, httpClient}) =>
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
  // The test binding stubs out HttpClient (every request returns 400);
  // these tests talk to a real in-process server over loopback.
  HttpOverrides.global = null;

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

  group('A2A hosting end-to-end', () {
    late InMemoryKeyValueStore kv;
    late ServiceProvider services;
    late A2AHostService host;

    setUp(() async {
      kv = InMemoryKeyValueStore();
      services = _buildServices(kv);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_localSource);
      await manager.saveModel(_localModel);
      await manager.saveAgent(_helper);
      host = A2AHostService(services, deviceName: 'Test Host');
      await host.start([_helper], port: 0);
    });

    tearDown(() => host.stop());

    /// A pairing payload addressed to the in-process host over loopback.
    Future<PairingPayload> loopbackOffer() async {
      final offer = await host.createPairingOffer();
      return PairingPayload(
        hostId: offer.hostId,
        host: '127.0.0.1',
        port: host.port!,
        token: offer.token,
        expiresAt: offer.expiresAt,
      );
    }

    test('pairs, stores only the bearer hash, and lists agents', () async {
      final client = PairingClient();

      final result = await client.pair(
        await loopbackOffer(),
        clientName: 'tester',
        clientId: 'client-1',
      );

      expect(result.deviceName, 'Test Host');
      expect(result.credential, isNotEmpty);

      // The raw bearer never lands in the host's key-value store.
      final keys = await kv.keys(prefix: 'agents_app.a2a.client.');
      expect(keys, hasLength(1));
      expect(keys.single, isNot(contains(result.credential)));
      expect(keys.single, contains(PairingCrypto.sha256Hex(result.credential)));

      final agents = await client.listAgents(
        'http://127.0.0.1:${host.port}',
        result.credential,
      );
      expect(agents.single.name, 'Helper');
      expect(agents.single.path, '/agents/helper');
    });

    test(
      'pairing tokens are single-use and bad bearers are rejected',
      () async {
        final client = PairingClient();
        final offer = await loopbackOffer();

        await client.pair(offer, clientName: 't', clientId: 'c1');

        await expectLater(
          client.pair(offer, clientName: 't', clientId: 'c2'),
          throwsA(isA<PairingException>()),
        );
        await expectLater(
          client.listAgents('http://127.0.0.1:${host.port}', 'wrong-bearer'),
          throwsA(isA<PairingException>()),
        );
      },
    );

    test('a paired device runs the remote agent through the factory', () async {
      final client = PairingClient();
      final result = await client.pair(
        await loopbackOffer(),
        clientName: 'tester',
        clientId: 'client-1',
      );

      // Register the paired host exactly as the pairing screen does.
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(
        ModelSourceConfig(
          id: 'net-${result.hostId}',
          providerType: ProviderType.network,
          displayName: result.deviceName,
          endpoint: 'http://127.0.0.1:${host.port}',
        ),
        apiKey: result.credential,
      );
      await manager.saveModel(
        ModelConfig(
          id: 'net-model',
          sourceId: 'net-${result.hostId}',
          modelId: '/agents/helper',
          displayName: 'Helper @ Test Host',
        ),
      );
      const remoteConfig = SavedAgentConfig(
        id: 'net-agent',
        name: 'Helper (remote)',
        modelId: 'net-model',
      );
      await manager.saveAgent(remoteConfig);

      final factory = services.getRequiredService<ConfiguredAgentFactory>();
      final remote = await factory.createAgent(remoteConfig);
      final session = await remote.createSession();
      final response = await remote.run(session, null, message: 'hello');

      expect(response.text, contains('ok'));
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

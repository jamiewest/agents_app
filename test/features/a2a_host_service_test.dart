import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

ServiceProvider _buildServices(
  InMemoryKeyValueStore kv, {
  ai.ChatClient Function()? chatClient,
}) =>
    (ServiceCollection()
          ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
          ..addConfiguredAgents(
            keyValueStore: (_) => kv,
            secretStore: (_) => InMemorySecretStore(),
            chatClientFactory: (_) => ConfiguredChatClientFactory(
              customClientResolver:
                  ({required source, required model, httpClient}) =>
                      chatClient?.call() ?? _EchoChatClient(),
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

    test('ping reflects reachability and credential validity', () async {
      final client = PairingClient();
      final result = await client.pair(
        await loopbackOffer(),
        clientName: 't',
        clientId: 'c1',
      );
      final baseUrl = 'http://127.0.0.1:${host.port}';

      expect(await client.ping(baseUrl, result.credential), isTrue);
      expect(await client.ping(baseUrl, 'wrong-bearer'), isFalse);

      await host.stop();
      expect(await client.ping(baseUrl, result.credential), isFalse);
    });

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

  group('A2A hosting run-slot and paths', () {
    late InMemoryKeyValueStore kv;
    late ServiceProvider services;
    late A2AHostService host;
    late _GatedChatClient gated;

    setUp(() async {
      kv = InMemoryKeyValueStore();
      gated = _GatedChatClient();
      services = _buildServices(kv, chatClient: () => gated);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_localSource);
      await manager.saveModel(_localModel);
      await manager.saveAgent(_helper);
      host = A2AHostService(services, deviceName: 'Test Host');
    });

    tearDown(() => host.stop());

    Future<String> pairedCredential() async {
      final offer = await host.createPairingOffer();
      final result = await PairingClient().pair(
        PairingPayload(
          hostId: offer.hostId,
          host: '127.0.0.1',
          port: host.port!,
          token: offer.token,
          expiresAt: offer.expiresAt,
        ),
        clientName: 'tester',
        clientId: 'client-1',
      );
      return result.credential;
    }

    test('streaming runs hold the single slot until the stream ends', () async {
      await host.start([_helper], port: 0);
      final credential = await pairedCredential();

      gated.gate = Completer<void>();
      final first = _streamRpc(host.port!, credential, 'r1');
      // Wait until the first run is inside the model call.
      await _until(() => gated.active == 1);

      final second = _streamRpc(host.port!, credential, 'r2');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The second request must queue on the run slot instead of driving
      // the model concurrently — even though the first request already
      // returned its SSE response headers.
      expect(gated.maxActive, 1);

      gated.gate!.complete();
      final bodies = await Future.wait([first, second]);
      expect(bodies[0], contains('ok'));
      expect(bodies[1], contains('ok'));
      expect(gated.maxActive, 1);
    });

    test('a failing streaming run releases the slot', () async {
      await host.start([_helper], port: 0);
      final credential = await pairedCredential();

      gated.failNextStream = true;
      await _streamRpc(host.port!, credential, 'boom');

      // The slot must be free again: a healthy run completes rather than
      // queueing forever behind a leaked lease.
      final body = await _streamRpc(host.port!, credential, 'after');
      expect(body, contains('ok'));
      expect(gated.maxActive, 1);
    });

    test('colliding agent names stay independently addressable', () async {
      const clone = SavedAgentConfig(
        id: 'a-helper2',
        name: 'HELPER!',
        modelId: 'm-local',
        description: 'Same slug, different agent.',
      );
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveAgent(clone);

      await host.start([_helper, clone], port: 0);
      final credential = await pairedCredential();

      final agents = await PairingClient().listAgents(
        'http://127.0.0.1:${host.port}',
        credential,
      );
      final paths = agents.map((agent) => agent.path).toSet();
      expect(paths, hasLength(2));
      expect(paths, contains('/agents/helper'));
      expect(paths, contains('/agents/helper-a-helper2'));
    });
  });
}

/// Posts a `message/stream` JSON-RPC request to the hosted helper agent and
/// drains the SSE response, returning the raw body text.
Future<String> _streamRpc(int port, String credential, String id) async {
  final client = HttpClient();
  try {
    final request = await client.post('127.0.0.1', port, '/agents/helper');
    request.headers
      ..set('authorization', 'Bearer $credential')
      ..contentType = ContentType.json;
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'message/stream',
        'params': {
          'message': {
            'kind': 'message',
            'messageId': 'msg-$id',
            'role': 'user',
            'parts': [
              {'kind': 'text', 'text': 'hi'},
            ],
          },
        },
      }),
    );
    final response = await request.close();
    return utf8.decodeStream(response);
  } finally {
    client.close();
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// An echo client whose model calls can be held open (to observe run
/// concurrency) or made to fail.
///
/// Both entry points are gated identically: the A2A handler may drive the
/// hosted agent through either, and the run-slot guarantee must hold for
/// whichever one carries the inference.
final class _GatedChatClient extends ai.ChatClient {
  /// While set, model calls wait on this before answering.
  Completer<void>? gate;

  /// Fails the next model call when true.
  bool failNextStream = false;

  /// Model calls currently in flight.
  int active = 0;

  /// The largest [active] ever observed.
  int maxActive = 0;

  Future<void> _enter() async {
    active++;
    maxActive = math.max(maxActive, active);
    if (failNextStream) {
      failNextStream = false;
      throw StateError('scripted model failure');
    }
    final pending = gate;
    if (pending != null) await pending.future;
  }

  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    try {
      await _enter();
      return ai.ChatResponse(
        messages: <ai.ChatMessage>[
          ai.ChatMessage.fromText(ai.ChatRole.assistant, 'ok'),
        ],
      );
    } finally {
      active--;
    }
  }

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    try {
      await _enter();
      yield ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok');
    } finally {
      active--;
    }
  }

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
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

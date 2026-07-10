import 'dart:convert';
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
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('probe message/stream body', () async {
    final kv = InMemoryKeyValueStore();
    final services = (ServiceCollection()
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
    final manager = services.getRequiredService<ConfiguredAgentsManager>();
    await manager.saveSource(_localSource);
    await manager.saveModel(_localModel);
    await manager.saveAgent(_helper);
    final host = A2AHostService(services, deviceName: 'Test Host');
    await host.start([_helper], port: 0);
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
    final client = HttpClient();
    final request = await client.post('127.0.0.1', host.port!, '/agents/helper');
    request.headers
      ..set('authorization', 'Bearer ${result.credential}')
      ..contentType = ContentType.json;
    request.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'r1',
      'method': 'message/stream',
      'params': {
        'message': {
          'kind': 'message',
          'messageId': 'msg-1',
          'role': 'user',
          'parts': [
            {'kind': 'text', 'text': 'hi'},
          ],
        },
      },
    }));
    final response = await request.close();
    // ignore: avoid_print
    print('STATUS ${response.statusCode} ${response.headers.contentType}');
    final body = await utf8.decodeStream(response);
    // ignore: avoid_print
    print('BODY <<<$body>>>');
    client.close();
    await host.stop();
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

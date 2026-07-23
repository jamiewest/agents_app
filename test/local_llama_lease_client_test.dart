import 'dart:async';
import 'dart:typed_data';

import 'package:agents_app/data/local_llama_lease_client.dart';
import 'package:agents_app/data/local_llama_model_host.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;
import 'package:flutter_test/flutter_test.dart';

class _FakeSession implements llama.LlamaSession {
  @override
  Stream<String> generate(
    String prompt, {
    int maxTokens = 256,
    double temperature = 0.8,
    int? topK,
    double? topP,
    int? seed,
    List<String> stopSequences = const <String>[],
    List<Uint8List>? media,
    List<llama.LlamaChatTurn>? turns,
    int sequenceId = 0,
    llama.LlamaStatsCallback? onStats,
  }) => const Stream<String>.empty();

  @override
  Future<void> cancel() async {}

  @override
  llama.LlamaSessionCapabilities get capabilities =>
      const llama.LlamaSessionCapabilities(
        canPersistState: false,
        reportsStateSize: false,
      );

  @override
  Future<int> saveState(String path, {int sequenceId = 0}) async => 0;

  @override
  Future<int> loadState(String path, {int sequenceId = 0}) async => 0;

  @override
  Future<int> stateSizeBytes({int sequenceId = 0}) async => 0;

  @override
  Future<llama.LlamaStashResult> stashState(
    String key, {
    int sequenceId = 0,
  }) async => (tokens: 0, bytes: 0);

  @override
  Future<int> restoreStashedState(String key, {int sequenceId = 0}) async => 0;

  @override
  Future<int> dropStashedState(String key) async => 0;

  @override
  Future<void> clearSequence(int sequenceId) async {}

  @override
  Future<void> setImageTokenBudget(int? imageTokenBudget) async {}

  @override
  Future<void> dispose() async {}
}

class _FakeRuntime implements llama.LlamaRuntime {
  @override
  bool get supportsMultiThreading => true;

  @override
  Future<llama.LlamaSession> loadModel(
    llama.ModelSpec spec, {
    String? localPath,
    String? localMmprojPath,
    String? localDraftPath,
    llama.LlamaLoadProgress? onProgress,
  }) async => _FakeSession();
}

/// An inner client whose behavior is injected per test.
class _FakeInnerClient extends ChatClient {
  _FakeInnerClient({this.streaming, this.respond});

  final Stream<ChatResponseUpdate> Function()? streaming;
  final Future<ChatResponse> Function()? respond;

  @override
  Future<ChatResponse> getResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => respond!();

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => streaming!();

  @override
  void dispose() {}
}

void main() {
  group('LeasedLocalLlamaChatClient', () {
    late LocalLlamaModelHost host;
    late _FakeSession session;

    Future<llama.LlamaSession> load(llama.LlamaRuntime _) async => session;

    LeasedLocalLlamaChatClient client(ChatClient inner) =>
        LeasedLocalLlamaChatClient(
          host: host,
          loadKey: 'model-a',
          ownerKey: 'A',
          retainKvState: true,
          buildClient: (_) => inner,
          load: load,
        );

    /// True when the host gate is currently free.
    Future<bool> gateIsFree() async {
      var granted = false;
      final pending = host
          .lease(loadKey: 'model-a', ownerKey: 'probe', load: load)
          .then((lease) {
            granted = true;
            lease.release();
          });
      await pumpEventQueue();
      if (!granted) return false;
      await pending;
      return true;
    }

    setUp(() {
      host = LocalLlamaModelHost(runtimeFactory: _FakeRuntime.new);
      session = _FakeSession();
    });

    test('releases the lease when the stream completes', () async {
      final inner = _FakeInnerClient(
        streaming: () => const Stream<ChatResponseUpdate>.empty(),
      );

      await client(
        inner,
      ).getStreamingResponse(messages: const <ChatMessage>[]).drain<void>();

      expect(await gateIsFree(), isTrue);
    });

    test('releases the lease when the subscriber cancels mid-stream', () async {
      // Never emits and never closes: only cancellation can end it.
      final controller = StreamController<ChatResponseUpdate>();
      addTearDown(controller.close);
      final inner = _FakeInnerClient(streaming: () => controller.stream);

      final subscription = client(
        inner,
      ).getStreamingResponse(messages: const <ChatMessage>[]).listen((_) {});
      await pumpEventQueue();
      expect(
        await gateIsFree(),
        isFalse,
        reason: 'the lease must be held while the stream is live',
      );

      await subscription.cancel();

      expect(
        await gateIsFree(),
        isTrue,
        reason: 'an abandoned stream must not wedge the host gate',
      );
    });

    test('releases the lease when the request fails', () async {
      final inner = _FakeInnerClient(
        respond: () async => throw StateError('boom'),
      );

      await expectLater(
        client(inner).getResponse(messages: const <ChatMessage>[]),
        throwsStateError,
      );

      expect(await gateIsFree(), isTrue);
    });

    test('a resident-only client surfaces the lease StateError', () async {
      final inner = _FakeInnerClient(
        streaming: () => const Stream<ChatResponseUpdate>.empty(),
      );
      final residentOnly = LeasedLocalLlamaChatClient(
        host: host,
        loadKey: 'model-a',
        ownerKey: 'title',
        retainKvState: false,
        buildClient: (_) => inner,
      );

      await expectLater(
        residentOnly
            .getStreamingResponse(messages: const <ChatMessage>[])
            .drain<void>(),
        throwsStateError,
      );

      expect(await gateIsFree(), isTrue);
    });
  });
}

import 'dart:typed_data';

import 'package:agents_app/data/local_llama_model_host.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;
import 'package:flutter_test/flutter_test.dart';

/// A session that records whether it was disposed.
class _FakeSession implements llama.LlamaSession {
  _FakeSession(this.label);

  final String label;
  bool disposed = false;

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
  Future<void> dispose() async => disposed = true;
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
  }) async => _FakeSession('runtime');
}

void main() {
  group('LocalLlamaModelHost', () {
    late LocalLlamaModelHost host;

    setUp(() {
      host = LocalLlamaModelHost(runtimeFactory: _FakeRuntime.new);
    });

    test('reuses the resident session for a matching key without reloading',
        () async {
      var loads = 0;
      Future<llama.LlamaSession> load(llama.LlamaRuntime _) async {
        loads++;
        return _FakeSession('a');
      }

      final first = await host.acquire('model-a', load);
      final second = await host.acquire('model-a', load);

      expect(loads, 1, reason: 'the second acquire must not run the loader');
      expect(identical(first, second), isTrue);
      expect((first as _FakeSession).disposed, isFalse);
    });

    test('disposes the resident session before loading a different model',
        () async {
      final a = _FakeSession('a');
      final b = _FakeSession('b');

      final first = await host.acquire('model-a', (_) async => a);
      final second = await host.acquire('model-b', (_) async => b);

      expect(identical(first, a), isTrue);
      expect(identical(second, b), isTrue);
      expect(a.disposed, isTrue, reason: 'the outgoing model must be freed');
      expect(b.disposed, isFalse);
    });

    test('leaves the slot empty after a failed load and recovers', () async {
      await expectLater(
        host.acquire('model-a', (_) async => throw StateError('boom')),
        throwsStateError,
      );

      final recovered = _FakeSession('b');
      final session = await host.acquire('model-b', (_) async => recovered);

      expect(identical(session, recovered), isTrue);
      expect(recovered.disposed, isFalse);
    });

    test('serializes overlapping acquires for different keys', () async {
      final a = _FakeSession('a');
      final b = _FakeSession('b');

      // Fire both before awaiting either; the gate must order them so the
      // first fully resolves (and is disposed) before the second loads.
      final firstFuture = host.acquire('model-a', (_) async => a);
      final secondFuture = host.acquire('model-b', (_) async => b);

      final results = await Future.wait([firstFuture, secondFuture]);

      expect(identical(results[0], a), isTrue);
      expect(identical(results[1], b), isTrue);
      expect(a.disposed, isTrue);
      expect(b.disposed, isFalse);
    });

    test('exposes the resident key and session, tracking eviction', () async {
      expect(host.currentKey, isNull);
      expect(host.currentSession, isNull);

      final a = _FakeSession('a');
      await host.acquire('model-a', (_) async => a);
      expect(host.currentKey, 'model-a');
      expect(identical(host.currentSession, a), isTrue);

      final b = _FakeSession('b');
      await host.acquire('model-b', (_) async => b);
      expect(host.currentKey, 'model-b');
      expect(identical(host.currentSession, b), isTrue);
    });
  });
}

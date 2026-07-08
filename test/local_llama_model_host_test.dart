import 'dart:typed_data';

import 'package:agents_app/data/local_llama_model_host.dart';
import 'package:agents_llama/agents_llama.dart' as llama;
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
    List<Uint8List>? images,
    List<llama.LlamaChatTurn>? turns,
    llama.LlamaStatsCallback? onStats,
  }) => const Stream<String>.empty();

  @override
  Future<void> cancel() async {}

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
  });
}

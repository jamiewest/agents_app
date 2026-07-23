import 'dart:typed_data';

import 'package:agents_app/data/local_llama_model_host.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;
import 'package:flutter_test/flutter_test.dart';

/// A session that records disposal and every stash-related call.
class _FakeSession implements llama.LlamaSession {
  _FakeSession(this.label, {this.canStash = false});

  final String label;
  final bool canStash;
  bool disposed = false;

  final List<String> stashCalls = <String>[];
  final List<String> restoreCalls = <String>[];
  final List<String> dropCalls = <String>[];

  /// Overrides the stash outcome per key; defaults to 10 tokens / 100 bytes.
  llama.LlamaStashResult Function(String key)? onStash;

  /// Overrides the restore outcome per key; defaults to 10 tokens.
  int Function(String key)? onRestore;

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
      llama.LlamaSessionCapabilities(
        canPersistState: false,
        reportsStateSize: false,
        canStashState: canStash,
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
  }) async {
    stashCalls.add(key);
    final custom = onStash;
    if (custom != null) return custom(key);
    return (tokens: 10, bytes: 100);
  }

  @override
  Future<int> restoreStashedState(String key, {int sequenceId = 0}) async {
    restoreCalls.add(key);
    final custom = onRestore;
    if (custom != null) return custom(key);
    return 10;
  }

  @override
  Future<int> dropStashedState(String key) async {
    dropCalls.add(key);
    return 0;
  }

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

    test(
      'reuses the resident session for a matching key without reloading',
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
      },
    );

    test(
      'disposes the resident session before loading a different model',
      () async {
        final a = _FakeSession('a');
        final b = _FakeSession('b');

        final first = await host.acquire('model-a', (_) async => a);
        final second = await host.acquire('model-b', (_) async => b);

        expect(identical(first, a), isTrue);
        expect(identical(second, b), isTrue);
        expect(a.disposed, isTrue, reason: 'the outgoing model must be freed');
        expect(b.disposed, isFalse);
      },
    );

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

  group('LocalLlamaModelHost.lease', () {
    late LocalLlamaModelHost host;
    late _FakeSession session;

    Future<llama.LlamaSession> load(llama.LlamaRuntime _) async => session;

    /// Leases for [ownerKey] and releases immediately, simulating one full
    /// request by that owner.
    Future<void> request(
      String ownerKey, {
      bool retain = true,
      String loadKey = 'model-a',
    }) async {
      final lease = await host.lease(
        loadKey: loadKey,
        ownerKey: ownerKey,
        retainKvState: retain,
        load: load,
      );
      lease.release();
    }

    setUp(() {
      host = LocalLlamaModelHost(runtimeFactory: _FakeRuntime.new);
      session = _FakeSession('a', canStash: true);
    });

    test('consecutive leases by one owner touch no stash state', () async {
      await request('A');
      await request('A');
      await request('A');

      expect(session.stashCalls, isEmpty);
      expect(session.restoreCalls, isEmpty);
      expect(session.dropCalls, isEmpty);
    });

    test('A -> B -> A stashes the outgoing owner and restores the returning '
        'one', () async {
      await request('A');
      await request('B');
      await request('A');

      // B's lease stashes A; B is cold so nothing restores. A's return
      // stashes B and restores A, then drops the consumed entry.
      expect(session.stashCalls, ['A', 'B']);
      expect(session.restoreCalls, ['A']);
      expect(session.dropCalls, contains('A'));
    });

    test('a non-retained owner is never stashed', () async {
      await request('A');
      await request('title', retain: false);
      await request('A');

      expect(session.stashCalls, ['A'], reason: 'title must not be stashed');
      expect(session.restoreCalls, ['A']);
    });

    test('a failed stash degrades to a cold return, not an error', () async {
      session.onStash = (key) => throw StateError('stash boom');

      await request('A');
      await request('B');
      await request('A');

      expect(
        session.restoreCalls,
        isEmpty,
        reason: 'nothing was stashed, so nothing may be restored',
      );
    });

    test('a failed restore degrades to re-prefill, not an error', () async {
      session.onRestore = (key) => throw StateError('restore boom');

      await request('A');
      await request('B');
      await request('A');

      expect(session.restoreCalls, ['A']);
      expect(
        session.dropCalls,
        contains('A'),
        reason: 'the unusable entry must still be freed',
      );

      // The owner's entry is gone; another round trip re-stashes cleanly.
      await request('B');
      expect(session.stashCalls, ['A', 'B', 'A']);
    });

    test('a zero-byte stash is not recorded and never restored', () async {
      session.onStash = (key) => (tokens: 0, bytes: 0);

      await request('A');
      await request('B');
      await request('A');

      expect(session.restoreCalls, isEmpty);
    });

    test('evicts the least recently stashed owner over budget', () async {
      host = LocalLlamaModelHost(
        runtimeFactory: _FakeRuntime.new,
        stashBudgetBytes: 250,
      );

      await request('A');
      await request('B'); // stashes A (100)
      await request('C'); // stashes B (100)
      await request('D'); // stashes C (100) -> 300 > 250, evicts A

      expect(session.dropCalls, contains('A'));

      // A must now cold-start rather than restore a dropped entry.
      await request('A');
      expect(session.restoreCalls, isNot(contains('A')));
    });

    test('drops a single stash that exceeds the whole budget', () async {
      host = LocalLlamaModelHost(
        runtimeFactory: _FakeRuntime.new,
        stashBudgetBytes: 250,
      );
      session.onStash = (key) => (tokens: 10, bytes: 300);

      await request('A');
      await request('B'); // A's stash alone exceeds the budget

      expect(session.dropCalls, contains('A'));

      await request('A');
      expect(session.restoreCalls, isEmpty);
    });

    test('a model change clears all stash bookkeeping', () async {
      final second = _FakeSession('b', canStash: true);

      await request('A');
      await request('B'); // stashes A on the first session

      final lease = await host.lease(
        loadKey: 'model-b',
        ownerKey: 'A',
        load: (_) async => second,
      );
      lease.release();

      expect(session.disposed, isTrue);
      expect(
        second.restoreCalls,
        isEmpty,
        reason: 'stashes died with the old session; A must cold-start',
      );
    });

    test('skips all stash work on engines without stash support', () async {
      session = _FakeSession('a', canStash: false);

      await request('A');
      await request('B');
      await request('A');

      expect(session.stashCalls, isEmpty);
      expect(session.restoreCalls, isEmpty);
      expect(session.dropCalls, isEmpty);
    });

    test('serializes leases: the next request waits for release', () async {
      final first = await host.lease(
        loadKey: 'model-a',
        ownerKey: 'A',
        load: load,
      );

      var secondGranted = false;
      final secondFuture = host
          .lease(loadKey: 'model-a', ownerKey: 'B', load: load)
          .then((lease) {
            secondGranted = true;
            return lease;
          });

      await pumpEventQueue();
      expect(
        secondGranted,
        isFalse,
        reason: 'the second lease must wait for the first to release',
      );

      first.release();
      final second = await secondFuture;
      expect(secondGranted, isTrue);
      second.release();
    });

    test('release is idempotent', () async {
      final first = await host.lease(
        loadKey: 'model-a',
        ownerKey: 'A',
        load: load,
      );
      first.release();
      first.release();

      await request('B');
    });

    test('a failed load rejects the lease without wedging the gate', () async {
      await expectLater(
        host.lease(
          loadKey: 'model-a',
          ownerKey: 'A',
          load: (_) async => throw StateError('boom'),
        ),
        throwsStateError,
      );

      await request('A');
    });

    test(
      'a resident-only lease throws when the model is not resident',
      () async {
        await expectLater(
          host.lease(loadKey: 'model-a', ownerKey: 'title'),
          throwsStateError,
        );

        await request('A');

        // Now resident: a matching resident-only lease succeeds...
        final lease = await host.lease(loadKey: 'model-a', ownerKey: 'title');
        lease.release();

        // ...and a mismatched one still refuses to trigger a load.
        await expectLater(
          host.lease(loadKey: 'model-b', ownerKey: 'title'),
          throwsStateError,
        );
      },
    );
  });
}

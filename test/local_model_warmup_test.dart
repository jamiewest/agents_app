import 'dart:async';

import 'package:agents_app/data/local_model_warmup.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter_test/flutter_test.dart';

ModelSourceConfig _source(String id, ProviderType type) =>
    ModelSourceConfig(id: id, providerType: type, displayName: id);

ModelConfig _model(String id, String sourceId) =>
    ModelConfig(id: id, sourceId: sourceId, modelId: '$id-wire');

SavedAgentConfig _agent(String id, String modelId) =>
    SavedAgentConfig(id: id, name: id, modelId: modelId);

void main() {
  group('chooseLocalWarmupTarget', () {
    final local = _source('local', ProviderType.localLlama);

    test('warms the single local model a local-only setup will need', () {
      final target = chooseLocalWarmupTarget(
        sources: [local],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'm')],
      );

      expect(target, isNotNull);
      expect(target!.model.id, 'm');
      expect(target.source.id, 'local');
    });

    test('warms once when several agents share one local model', () {
      final target = chooseLocalWarmupTarget(
        sources: [local],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'm'), _agent('b', 'm')],
      );

      expect(target?.model.id, 'm');
    });

    test('declines when agents reference two distinct local models', () {
      // Only one model fits in memory; guessing wrong costs a load plus an
      // eviction on the first message.
      final target = chooseLocalWarmupTarget(
        sources: [local],
        models: [_model('m1', 'local'), _model('m2', 'local')],
        agents: [_agent('a', 'm1'), _agent('b', 'm2')],
      );

      expect(target, isNull);
    });

    test('declines when a cloud source is also configured', () {
      final target = chooseLocalWarmupTarget(
        sources: [local, _source('cloud', ProviderType.anthropic)],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'm')],
      );

      expect(target, isNull);
    });

    test('declines a keyless cloud source too', () {
      // A source with no stored key is still an engine the user set up and
      // may key at any moment; warming would prime the wrong one.
      final target = chooseLocalWarmupTarget(
        sources: [local, _source('cloud', ProviderType.openAiCompatible)],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'm')],
      );

      expect(target, isNull);
    });

    test('declines when a paired network source is configured', () {
      final target = chooseLocalWarmupTarget(
        sources: [local, _source('paired', ProviderType.network)],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'm')],
      );

      expect(target, isNull);
    });

    test('declines when no agent references the local model', () {
      final target = chooseLocalWarmupTarget(
        sources: [local],
        models: [_model('m', 'local')],
        agents: const [],
      );

      expect(target, isNull);
    });

    test('declines when an agent points at a model that no longer exists', () {
      final target = chooseLocalWarmupTarget(
        sources: [local],
        models: [_model('m', 'local')],
        agents: [_agent('a', 'deleted')],
      );

      expect(target, isNull);
    });

    test('declines when nothing is configured at all', () {
      final target = chooseLocalWarmupTarget(
        sources: const [],
        models: const [],
        agents: const [],
      );

      expect(target, isNull);
    });
  });

  group('LocalModelWarmup', () {
    late ConfiguredAgentsManager manager;

    setUp(() async {
      final services =
          (ServiceCollection()..addConfiguredAgents(
                keyValueStore: (_) => InMemoryKeyValueStore(),
                secretStore: (_) => InMemorySecretStore(),
              ))
              .buildServiceProvider();
      manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_source('local', ProviderType.localLlama));
      await manager.saveModel(_model('m', 'local'));
      await manager.saveAgent(_agent('a', 'm'));
    });

    test('warms after the bootstrap future completes, never before', () async {
      // A file-backed model is only resolvable once bootstrap has
      // re-registered its picked path, so warming early would fail.
      final bootstrap = Completer<void>();
      var warmed = false;

      final warmup = LocalModelWarmup(
        manager: manager,
        ready: () => bootstrap.future,
        warm: (_) async {
          warmed = true;
          return true;
        },
        settleDelay: Duration.zero,
      );
      unawaited(warmup.start());

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(warmed, isFalse, reason: 'warmed before bootstrap finished');

      bootstrap.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(warmed, isTrue);
    });

    test('stop() before the settle elapses prevents the load', () async {
      var warmed = false;
      final warmup = LocalModelWarmup(
        manager: manager,
        ready: () async {},
        warm: (_) async {
          warmed = true;
          return true;
        },
        settleDelay: const Duration(milliseconds: 50),
      );
      unawaited(warmup.start());

      warmup.stop();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(warmed, isFalse);
    });

    test('a failing warm never escapes start()', () async {
      final warmup = LocalModelWarmup(
        manager: manager,
        ready: () async {},
        warm: (_) async => throw StateError('no runtime'),
        settleDelay: Duration.zero,
      );

      await expectLater(warmup.start(), completes);
    });

    test('start() is idempotent', () async {
      var warmCount = 0;
      final warmup = LocalModelWarmup(
        manager: manager,
        ready: () async {},
        warm: (_) async {
          warmCount++;
          return true;
        },
        settleDelay: Duration.zero,
      );

      await warmup.start();
      await warmup.start();
      expect(warmCount, 1);
    });
  });
}

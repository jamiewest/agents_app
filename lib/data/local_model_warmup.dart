/// Startup warm-up for a local-only setup.
///
/// A local GGUF takes seconds to become resident, and today that cost lands
/// on the user's first message: the model loads inside the first
/// `getStreamingResponse` call while they wait for a reply. When the app has
/// nothing *but* local inference configured, the model that first message
/// will need is knowable at launch — so it is loaded in the background
/// instead, and the first reply starts generating immediately.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';

/// The local model to make resident before the user's first message.
class LocalWarmupTarget {
  /// Creates a target.
  const LocalWarmupTarget({required this.source, required this.model});

  /// The local source [model] belongs to.
  final ModelSourceConfig source;

  /// The model to load.
  final ModelConfig model;
}

/// Picks the local model worth warming, or null when none is.
///
/// Warming is deliberately narrow, because the machine holds exactly one
/// model at a time and a wrong guess costs a load plus an eviction on the
/// user's first message — strictly worse than loading lazily. All three
/// conditions must hold:
///
/// * every configured source is [ProviderType.localLlama], so local
///   inference is not merely *available* but the only engine set up. A
///   configured cloud source counts even without a stored key: the user set
///   it up and may key it at any moment, and warming a local model in that
///   state would prime an engine the next message might not use.
/// * at least one saved agent resolves to a model on one of those sources,
///   so something can actually run.
/// * those agents reference exactly one distinct model. With two, there is
///   no way to know which the user will open first, and loading the wrong
///   one makes the first message slower than doing nothing.
///
/// Pure, so the policy is testable without a runtime, a host, or a model
/// file.
LocalWarmupTarget? chooseLocalWarmupTarget({
  required List<ModelSourceConfig> sources,
  required List<ModelConfig> models,
  required List<SavedAgentConfig> agents,
}) {
  if (sources.isEmpty) return null;
  if (sources.any((s) => s.providerType != ProviderType.localLlama)) {
    return null;
  }

  final localSources = <String, ModelSourceConfig>{
    for (final source in sources) source.id: source,
  };
  final modelsById = <String, ModelConfig>{
    for (final model in models) model.id: model,
  };

  final referenced = <String, LocalWarmupTarget>{};
  for (final agent in agents) {
    final model = modelsById[agent.modelId];
    if (model == null) continue;
    final source = localSources[model.sourceId];
    if (source == null) continue;
    referenced[model.id] = LocalWarmupTarget(source: source, model: model);
  }

  if (referenced.length != 1) return null;
  return referenced.values.first;
}

/// Loads the local model a local-only setup is certain to need, once, in the
/// background at startup.
///
/// Not a [BackgroundService]: it must run *after* [ready] — the bootstrap
/// pass that re-registers picked GGUF paths from a previous session — and a
/// hosted service starting off `host.run()` would race it and find a
/// file-backed model unresolvable.
class LocalModelWarmup {
  /// Creates a warm-up.
  ///
  /// [ready] is awaited first (app bootstrap). [warm] performs the load and
  /// reports whether it happened; it is expected to decline models whose
  /// weights are not downloaded yet. [settleDelay] keeps the load off the
  /// first frames, where it would compete with the work the user can see.
  LocalModelWarmup({
    required this.manager,
    required this.ready,
    required this.warm,
    this.settleDelay = const Duration(seconds: 3),
  });

  /// Reads the configured sources, models, and agents.
  final ConfiguredAgentsManager manager;

  /// Startup work that must finish before configuration can be trusted.
  final Future<void> Function() ready;

  /// Makes the chosen model resident; returns whether it did.
  final Future<bool> Function(LocalWarmupTarget target) warm;

  /// How long to wait after [ready] before loading.
  final Duration settleDelay;

  bool _stopped = false;
  bool _started = false;

  /// Runs the warm-up in the background. Safe to call once; later calls are
  /// ignored.
  ///
  /// Never rethrows: a warm-up that fails leaves the app exactly where it
  /// was, with the model loading on the first message as before.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await ready();
      if (_stopped) return;
      await Future<void>.delayed(settleDelay);
      if (_stopped) return;

      final target = chooseLocalWarmupTarget(
        sources: await manager.sources.listSources(),
        models: await manager.sources.listModels(),
        agents: await manager.agents.listAgents(),
      );
      if (target == null || _stopped) return;

      developer.log(
        'Warming local model "${target.model.label}" — it is the only '
        'inference engine configured.',
        name: 'local_llama.warmup',
      );
      // The load itself cannot be cancelled: llama.cpp offers no abort and
      // the host's acquire runs to completion. [stop] therefore prevents a
      // load from *starting*, not from finishing.
      if (await warm(target)) {
        developer.log(
          'Local model "${target.model.label}" is resident; the first '
          'message will not wait for it to load.',
          name: 'local_llama.warmup',
        );
      }
    } on Object catch (error, stackTrace) {
      developer.log(
        'Local model warm-up failed; the model will load on first use.',
        name: 'local_llama.warmup',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Prevents a not-yet-started load from starting.
  void stop() => _stopped = true;
}

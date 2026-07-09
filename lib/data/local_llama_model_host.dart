import 'dart:async';

import 'package:agents_llama/agents_llama.dart' as llama;

/// Owns the single local llama model that may be resident at one time.
///
/// Running more than one llama.cpp model at once is not viable on the target
/// hardware, so this host keeps at most one loaded [llama.LlamaSession] backed
/// by a single shared worker [llama.LlamaRuntime]. Chat clients resolve their
/// session through [acquire]: when the requested model matches the resident one
/// it is reused with no reload, and when it differs the resident session is
/// disposed before the new model loads.
///
/// Reuse keeps the multi-gigabyte weights resident across agent switches; it
/// does not preserve the KV-cache prefix, so a switch to a same-model agent
/// with a different system prompt still re-prefills — that is inherent, not a
/// reload.
///
/// The host assumes one active local conversation at a time. Two *different*
/// local models wanted at once (for example a local delegating agent with a
/// local delegate on another model) evict each other through the single slot;
/// that scenario is unsupported on the target hardware, which cannot hold two
/// models regardless.
class LocalLlamaModelHost {
  /// Creates a host.
  ///
  /// [runtimeFactory] overrides how the shared runtime is created; it defaults
  /// to [llama.createLlamaRuntime] and exists so tests can inject a fake.
  LocalLlamaModelHost({llama.LlamaRuntime Function()? runtimeFactory})
    : _runtimeFactory = runtimeFactory ?? llama.createLlamaRuntime;

  final llama.LlamaRuntime Function() _runtimeFactory;

  llama.LlamaRuntime? _runtime;
  String? _currentKey;
  llama.LlamaSession? _current;

  // Serializes acquire calls so an eviction or load never runs while another
  // load for a different key is still in flight.
  Future<void> _gate = Future<void>.value();

  llama.LlamaRuntime get _sharedRuntime => _runtime ??= _runtimeFactory();

  /// Whether the shared runtime can run inference on multiple threads.
  bool get supportsMultiThreading => _sharedRuntime.supportsMultiThreading;

  /// The load key of the resident model, or null when none is loaded.
  ///
  /// Set and cleared together with the resident session, so a non-null value
  /// means a session is loaded. Lets a caller reuse the resident model — by
  /// passing this exact key to [acquire], which cache-hits without reloading —
  /// instead of forcing a load or eviction.
  String? get currentKey => _currentKey;

  /// Returns the session for the model identified by [key], loading it through
  /// [load] on a miss.
  ///
  /// A cache hit — the resident model already matches [key] — returns the
  /// loaded session without calling [load]. A miss disposes the resident
  /// session first (if any), then runs [load] on the shared runtime, so only
  /// one model is ever resident. If [load] throws, the resident slot is left
  /// empty and the error propagates to the caller.
  Future<llama.LlamaSession> acquire(
    String key,
    Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime) load,
  ) {
    final run = _gate.then((_) async {
      final current = _current;
      if (current != null && _currentKey == key) return current;

      if (current != null) {
        _current = null;
        _currentKey = null;
        await current.dispose();
      }

      final session = await load(_sharedRuntime);
      _current = session;
      _currentKey = key;
      return session;
    });
    // Keep the gate resolved even when this acquire fails, so a failed load
    // does not wedge every later request.
    _gate = run.then((_) {}, onError: (_) {});
    return run;
  }
}

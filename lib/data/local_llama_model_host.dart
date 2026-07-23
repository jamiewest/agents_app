import 'dart:async';
import 'dart:developer' as developer;

import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;

/// Owns the single local llama model that may be resident at one time.
///
/// Running more than one llama.cpp model at once is not viable on the target
/// hardware, so this host keeps at most one loaded [llama.LlamaSession] backed
/// by a single shared worker [llama.LlamaRuntime]. Chat clients resolve their
/// session through [lease]: when the requested model matches the resident one
/// it is reused with no reload, and when it differs the resident session is
/// disposed before the new model loads.
///
/// Reuse keeps the multi-gigabyte weights resident across agent switches. On
/// engines that support in-memory KV stashing, the host additionally keeps
/// each owner's KV-cache lineage alive across switches: when a lease changes
/// the active owner, the outgoing owner's sequence-0 state is stashed and the
/// incoming owner's stash (if any) is restored, so returning to a warm
/// conversation resumes with a cached prefix instead of a full re-prefill.
/// Stash and restore failures degrade to a re-prefill; they never fail the
/// request.
///
/// A lease also serializes the whole model request — including a streamed
/// response — so no other owner can swap KV state or evict the model while a
/// response is still being generated ([llama.LlamaSession.generate]
/// supersedes an in-flight run rather than queueing behind it).
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
  ///
  /// [stashBudgetBytes] caps the total engine-side memory the host keeps in
  /// KV stashes; it defaults to [defaultStashBudgetBytes] and is overridable
  /// so tests can exercise eviction with small numbers.
  LocalLlamaModelHost({
    llama.LlamaRuntime Function()? runtimeFactory,
    this.stashBudgetBytes = defaultStashBudgetBytes,
  }) : _runtimeFactory = runtimeFactory ?? llama.createLlamaRuntime;

  /// Default cap on total stashed KV state: 512 MiB.
  ///
  /// Deliberately conservative — a stash is a full in-RAM copy of a
  /// sequence's KV cache, and on the constrained devices this app targets an
  /// out-of-memory kill is strictly worse than the re-prefill a dropped
  /// stash degrades to. Note that a single long conversation on a
  /// multi-billion-parameter model can exceed this by itself (KV state is
  /// commonly ~100-150 KB per token); such oversized stashes are dropped
  /// with a loud log rather than kept.
  static const int defaultStashBudgetBytes = 512 << 20;

  /// Cap on total engine-side stash memory. See [defaultStashBudgetBytes].
  final int stashBudgetBytes;

  final llama.LlamaRuntime Function() _runtimeFactory;

  llama.LlamaRuntime? _runtime;
  String? _currentKey;
  llama.LlamaSession? _current;

  // Serializes all host turns (loads, evictions, and leased requests) so an
  // owner switch or model swap never runs while another request is still
  // streaming.
  Future<void> _gate = Future<void>.value();

  // Owner whose KV lineage currently occupies sequence 0, and whether that
  // state is worth stashing when another owner takes over. Null until the
  // first lease on a stash-capable session.
  String? _kvOwner;
  bool _kvOwnerRetained = false;

  // Stashed bytes per owner key, insertion-ordered oldest-first so eviction
  // is LRU by last stash. Mirrors the engine-side stash exactly: entries are
  // added on a successful stash and removed on restore, eviction, or model
  // change.
  final Map<String, int> _stashedBytes = <String, int>{};

  llama.LlamaRuntime get _sharedRuntime => _runtime ??= _runtimeFactory();

  /// Whether the shared runtime can run inference on multiple threads.
  bool get supportsMultiThreading => _sharedRuntime.supportsMultiThreading;

  /// The load key of the resident model, or null when none is loaded.
  ///
  /// Set and cleared together with the resident session, so a non-null value
  /// means a session is loaded. Lets a caller cheaply pre-check whether a
  /// resident-only [lease] (null loader) can possibly succeed; the
  /// authoritative check happens again inside the lease turn.
  String? get currentKey => _currentKey;

  /// The resident session, or null when none is loaded.
  ///
  /// Reading it never loads or evicts. Prefer [lease] for any generation
  /// work — direct use bypasses request serialization and KV ownership.
  llama.LlamaSession? get currentSession => _current;

  /// Returns the session for the model identified by [key], loading it
  /// through [load] on a miss.
  ///
  /// A cache hit — the resident model already matches [key] — returns the
  /// loaded session without calling [load]. A miss disposes the resident
  /// session first (if any), then runs [load] on the shared runtime, so only
  /// one model is ever resident. If [load] throws, the resident slot is left
  /// empty and the error propagates to the caller.
  ///
  /// This resolves residency only; it grants no exclusivity and performs no
  /// KV owner switch. Use [lease] to run a request.
  Future<llama.LlamaSession> acquire(
    String key,
    Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime) load,
  ) {
    final run = _gate.then((_) => _ensureSession(key, load));
    // Keep the gate resolved even when this acquire fails, so a failed load
    // does not wedge every later request.
    _gate = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Grants exclusive use of the session for the model identified by
  /// [loadKey], with sequence 0 holding [ownerKey]'s KV lineage.
  ///
  /// The lease is exclusive: later leases (and [acquire] calls) wait until
  /// [LlamaSessionLease.release] is called, so callers must hold it for
  /// exactly one model request — including draining a streamed response —
  /// and release it in a `finally`.
  ///
  /// When [ownerKey] differs from the previous lease's owner and the engine
  /// supports stashing, the previous owner's sequence-0 state is stashed
  /// (only if that lease asked for retention) and [ownerKey]'s stash is
  /// restored when one exists. A cold owner simply generates over whatever
  /// is left in sequence 0: the engine's ledger reuses any common prompt
  /// prefix (for example a shared system prompt) and re-prefills the rest,
  /// so no explicit clear is needed. [retainKvState] controls whether *this*
  /// owner's state is stashed when a different owner takes over later; pass
  /// false for one-shot work (title generation, internal calls) whose state
  /// is never worth keeping.
  ///
  /// [load] resolves a residency miss exactly like [acquire]. Passing null
  /// makes the lease resident-only: it throws [StateError] instead of
  /// loading when the resident model does not match [loadKey], for
  /// background work that must never trigger a load or eviction.
  Future<LlamaSessionLease> lease({
    required String loadKey,
    required String ownerKey,
    bool retainKvState = true,
    Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime)? load,
  }) {
    final granted = Completer<LlamaSessionLease>();
    final released = Completer<void>();
    final turn = _gate.then((_) async {
      final llama.LlamaSession session;
      try {
        if (load != null) {
          session = await _ensureSession(loadKey, load);
        } else {
          final current = _current;
          if (current == null || _currentKey != loadKey) {
            throw StateError('Local model is no longer resident.');
          }
          session = current;
        }
        await _activateOwner(session, ownerKey, retainKvState);
      } on Object catch (error, stackTrace) {
        granted.completeError(error, stackTrace);
        return;
      }
      granted.complete(
        LlamaSessionLease._(session, () {
          if (!released.isCompleted) released.complete();
        }),
      );
      await released.future;
    });
    _gate = turn.then((_) {}, onError: (_) {});
    return granted.future;
  }

  Future<llama.LlamaSession> _ensureSession(
    String key,
    Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime) load,
  ) async {
    final current = _current;
    if (current != null && _currentKey == key) return current;

    if (current != null) {
      _current = null;
      _currentKey = null;
      // The engine-side stash lives and dies with the session, so every
      // stash entry is gone the moment the session is; drop the bookkeeping
      // with it so a later same-owner lease cold-starts instead of
      // attempting a restore that cannot succeed.
      _resetKvBookkeeping();
      await current.dispose();
    }

    final session = await load(_sharedRuntime);
    _current = session;
    _currentKey = key;
    return session;
  }

  void _resetKvBookkeeping() {
    _kvOwner = null;
    _kvOwnerRetained = false;
    _stashedBytes.clear();
  }

  Future<void> _activateOwner(
    llama.LlamaSession session,
    String ownerKey,
    bool retainKvState,
  ) async {
    // Engines without stash support (web/wllama) keep today's behavior:
    // every owner switch re-prefills through the engine's prefix ledger.
    if (!session.capabilities.canStashState) return;

    final outgoing = _kvOwner;
    if (outgoing == ownerKey) {
      _kvOwnerRetained = retainKvState;
      return;
    }
    if (outgoing != null && _kvOwnerRetained) {
      await _stashOwner(session, outgoing);
    }
    if (_stashedBytes.containsKey(ownerKey)) {
      await _restoreOwner(session, ownerKey);
    }
    _kvOwner = ownerKey;
    _kvOwnerRetained = retainKvState;
  }

  Future<void> _stashOwner(llama.LlamaSession session, String ownerKey) async {
    _stashedBytes.remove(ownerKey);
    try {
      final result = await session.stashState(ownerKey);
      if (result.bytes <= 0) {
        // Nothing reusable was cached; make sure no stale engine entry from
        // an earlier lineage survives under this key.
        await session.dropStashedState(ownerKey);
        return;
      }
      if (result.bytes > stashBudgetBytes) {
        await session.dropStashedState(ownerKey);
        developer.log(
          'KV stash for "$ownerKey" dropped: ${result.bytes} bytes '
          '(${result.tokens} tokens, '
          '${result.tokens > 0 ? result.bytes ~/ result.tokens : 0} B/token) '
          'exceeds the $stashBudgetBytes-byte budget by itself; this owner '
          'will re-prefill on return.',
          name: 'local_llama.kv',
        );
        return;
      }
      _stashedBytes[ownerKey] = result.bytes;
      developer.log(
        'KV stashed for "$ownerKey": ${result.tokens} tokens, '
        '${result.bytes} bytes '
        '(total ${_totalStashedBytes()} bytes in ${_stashedBytes.length} '
        'entries).',
        name: 'local_llama.kv',
      );
      await _evictWhileOverBudget(session);
    } on Object catch (error) {
      // A failed stash is a cache miss for this owner, never a generation
      // failure: the active request proceeds and the owner re-prefills on
      // return.
      _stashedBytes.remove(ownerKey);
      developer.log(
        'KV stash for "$ownerKey" failed; it will re-prefill on return: '
        '$error',
        name: 'local_llama.kv',
      );
    }
  }

  Future<void> _restoreOwner(
    llama.LlamaSession session,
    String ownerKey,
  ) async {
    _stashedBytes.remove(ownerKey);
    try {
      final tokens = await session.restoreStashedState(ownerKey);
      developer.log(
        'KV restored for "$ownerKey": $tokens tokens.',
        name: 'local_llama.kv',
      );
    } on Object catch (error) {
      // The engine leaves the sequence empty on a failed restore, so the
      // request simply re-prefills; degrade, never fail.
      developer.log(
        'KV restore for "$ownerKey" failed; re-prefilling: $error',
        name: 'local_llama.kv',
      );
    } finally {
      // Whether restored into sequence 0 or proven unusable, the engine-side
      // copy no longer earns its memory; the owner is re-stashed fresh on
      // its next switch-away.
      try {
        await session.dropStashedState(ownerKey);
      } on Object catch (error) {
        developer.log(
          'Dropping KV stash "$ownerKey" failed: $error',
          name: 'local_llama.kv',
        );
      }
    }
  }

  Future<void> _evictWhileOverBudget(llama.LlamaSession session) async {
    while (_totalStashedBytes() > stashBudgetBytes &&
        _stashedBytes.isNotEmpty) {
      final oldest = _stashedBytes.keys.first;
      final bytes = _stashedBytes.remove(oldest);
      try {
        await session.dropStashedState(oldest);
      } on Object catch (error) {
        developer.log(
          'Dropping KV stash "$oldest" failed: $error',
          name: 'local_llama.kv',
        );
      }
      developer.log(
        'KV stash for "$oldest" evicted (LRU, $bytes bytes); it will '
        're-prefill on return.',
        name: 'local_llama.kv',
      );
    }
  }

  int _totalStashedBytes() =>
      _stashedBytes.values.fold(0, (sum, bytes) => sum + bytes);
}

/// Exclusive use of the resident session, granted by
/// [LocalLlamaModelHost.lease].
///
/// Holders must call [release] when their request — including a streamed
/// response — finishes, is cancelled, or fails; until then every other local
/// model request waits. [release] is idempotent.
class LlamaSessionLease {
  LlamaSessionLease._(this.session, this._release);

  /// The resident session, with sequence 0 holding the leased owner's KV
  /// lineage. Valid only until [release].
  final llama.LlamaSession session;

  final void Function() _release;
  bool _released = false;

  /// Ends the lease, letting the next queued request take the session.
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

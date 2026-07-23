import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;

import 'local_llama_model_host.dart';

/// A [ChatClient] that runs every request inside a [LocalLlamaModelHost]
/// lease.
///
/// Each call acquires a lease — resolving the session and switching KV
/// ownership to [ownerKey] — builds a fresh session-bound client through
/// [buildClient], and releases the lease when the response (streamed or not)
/// completes, errors, or its subscription is cancelled. Holding the lease
/// across the whole request is what stops a concurrent local request from
/// superseding an in-flight generation or swapping KV state mid-stream.
class LeasedLocalLlamaChatClient extends ChatClient {
  /// Creates a client that leases [host]'s session per request.
  LeasedLocalLlamaChatClient({
    required this.host,
    required this.loadKey,
    required this.ownerKey,
    required this.retainKvState,
    required this.buildClient,
    this.load,
  });

  /// The host owning the single resident local model.
  final LocalLlamaModelHost host;

  /// Identifies the model, artifacts, and load parameters this client needs.
  final String loadKey;

  /// The KV owner this client's requests run as; see
  /// [LocalLlamaModelHost.lease].
  final String ownerKey;

  /// Whether this owner's KV state is stashed when another owner takes over.
  final bool retainKvState;

  /// Builds the raw llama chat client bound to the leased session, so the
  /// request can never acquire a second session or observe a model swap
  /// mid-request.
  final ChatClient Function(llama.LlamaSession session) buildClient;

  /// Resolves a residency miss; null makes every request resident-only
  /// (throwing instead of loading), for background work such as title
  /// generation.
  final Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime)? load;

  Future<LlamaSessionLease> _lease() => host.lease(
    loadKey: loadKey,
    ownerKey: ownerKey,
    retainKvState: retainKvState,
    load: load,
  );

  @override
  Future<ChatResponse> getResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    final lease = await _lease();
    try {
      return await buildClient(lease.session).getResponse(
        messages: messages,
        options: options,
        cancellationToken: cancellationToken,
      );
    } finally {
      lease.release();
    }
  }

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    if (cancellationToken?.isCancellationRequested ?? false) return;
    final lease = await _lease();
    // The finally also runs when the subscriber cancels the subscription
    // mid-stream, so an abandoned response can never wedge the host gate.
    try {
      yield* buildClient(lease.session).getStreamingResponse(
        messages: messages,
        options: options,
        cancellationToken: cancellationToken,
      );
    } finally {
      lease.release();
    }
  }

  @override
  void dispose() {
    // The session is owned by the host, not by this client.
  }
}

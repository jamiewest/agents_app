// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import '../../llm_exception.dart';

/// Represents a response from an LLM (Language Learning Model).
///
/// This class manages the streaming of LLM responses, error handling, and
/// cleanup.
class LlmResponse {
  /// Creates an LlmResponse.
  ///
  /// [stream] is the stream of text chunks from the LLM. [onDone] is an
  /// optional callback for when the response is complete or encounters an
  /// error.
  LlmResponse({
    required Stream<String> stream,
    required this.onUpdate,
    required this.onDone,
  }) {
    _subscription = stream.listen(
      onUpdate,
      onDone: () => _finish(null),
      cancelOnError: true,
      onError: (err) => _finish(_exception(err)),
    );
  }

  /// Callback function to be called when a new chunk is received from the
  /// response stream.
  final void Function(String text) onUpdate;

  /// Callback function to be called when the response is complete or encounters
  /// an error.
  final void Function(LlmException? error) onDone;

  /// Cancels the response stream.
  ///
  /// Safe to call repeatedly or after the stream has already completed;
  /// [onDone] fires at most once per response.
  void cancel() => _finish(const LlmCancelException());

  /// Detaches from the stream without reporting a result.
  ///
  /// For provider swaps: stops consuming the old provider's stream while
  /// suppressing the cancel snackbar/CANCEL-append that [onDone] would
  /// drive.
  void detach() {
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
  }

  StreamSubscription<String>? _subscription;

  LlmException _exception(dynamic err) => switch (err) {
    (LlmCancelException _) => const LlmCancelException(),
    (final LlmFailureException ex) => ex,
    _ => LlmFailureException(err.toString()),
  };

  void _finish(LlmException? error) {
    final subscription = _subscription;
    if (subscription == null) return;
    // Null before the callbacks so a re-entrant cancel is a no-op.
    _subscription = null;
    unawaited(subscription.cancel());
    onDone(error);
  }
}

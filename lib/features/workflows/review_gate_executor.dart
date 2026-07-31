// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

/// A reviewer's reply to a review-gate request.
///
/// Distinct from `String` on purpose: the agents' chat protocol already
/// accepts strings, so replies travel as a type only review gates accept.
class ReviewReply {
  /// Creates a review reply carrying [text].
  const ReviewReply(this.text);

  /// The reviewer's feedback.
  final String text;
}

/// Holds a draft, raises a review request, and applies the reply.
///
/// Handles two message shapes: the draft messages arriving from an
/// upstream stage (stores them and pauses the run via [port]), and the
/// [ReviewReply] delivered when the human answers (returns the draft plus
/// the feedback as a user message, which flows to the next stage). One
/// executor plays both parts so the reply lands on an executor that has
/// already run.
class ReviewGateExecutor extends Executor<Object, List<ChatMessage>?> {
  /// Creates a gate with the given executor id, pausing on its own port.
  ReviewGateExecutor(super.id);

  /// The request port this gate pauses on; its id equals the executor id.
  ///
  /// The response type is nullable as a leftover workaround: the engine used
  /// to force `null` into `TResponse`. Since agents 2.0.0 `sendRequest`
  /// returns an `ExternalResponse.pending` placeholder instead, and this gate
  /// discards that return anyway, so a `RequestPort<String, ReviewReply>`
  /// now round trips. Safe to simplify once the app builds again.
  late final RequestPort<String, ReviewReply?> port =
      RequestPort<String, ReviewReply?>(id);

  List<ChatMessage> _draft = const [];

  @override
  void configureProtocol(ProtocolBuilder builder) {
    builder
      ..acceptsMessage<List<ChatMessage>>()
      ..acceptsMessage<ReviewReply>()
      ..sendsMessage<List<ChatMessage>>();
  }

  @override
  Future<List<ChatMessage>?> handle(
    Object message,
    WorkflowContext context, {
    CancellationToken? cancellationToken,
  }) async {
    if (message case final List<ChatMessage> messages) {
      _draft = messages;
      final draftText = messages
          .where((m) => m.role == ChatRole.assistant)
          .map((m) => m.text)
          .join('\n');
      await context.sendRequest(
        port,
        draftText,
        cancellationToken: cancellationToken,
      );
      return null;
    }
    if (message case final ReviewReply reply) {
      return [
        ..._draft,
        ChatMessage.fromText(ChatRole.user, 'Reviewer feedback: ${reply.text}'),
      ];
    }
    return null;
  }
}

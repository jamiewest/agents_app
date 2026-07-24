// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

/// An [AgentScope] that also carries the identity needed to attribute token
/// usage to an agent and to a single run.
///
/// The package's usage ledger is keyed on [AgentScope], which knows the
/// conversation and session but not which agent is running or which turn is
/// in flight. This subclass adds both so `usage_records` rows can be grouped
/// by agent and joined back to an `AgentRunRecord`.
///
/// Two design points matter:
///
/// * [agentId] is a plain field because it is fixed once the scope is built,
///   but [runIdResolver] is a callback — a chat scope is created once when
///   the conversation opens and then serves many turns, so the run id has to
///   be read at the moment a usage record is written. This mirrors the
///   existing [AgentScope.sessionIdResolver] contract, which the package
///   already evaluates lazily inside `UsageTrackingChatClient`.
/// * [child] is overridden so delegate agents keep the initiating agent's
///   identity. The package derives delegate scopes through that one call, so
///   overriding it is what makes delegated work roll up to the agent the
///   user actually invoked.
class AgentRunScope extends AgentScope {
  /// Creates an [AgentRunScope] for [agentId].
  AgentRunScope({
    required super.conversationId,
    required super.sessionIdResolver,
    required this.agentId,
    required this.runIdResolver,
    super.channelId,
    super.isPrivate,
  });

  /// The saved agent configuration this scope runs.
  ///
  /// For a delegate scope this stays the *initiating* agent's id, so
  /// delegated model calls are attributed to the run the user started.
  final String agentId;

  /// Supplies the id of the run currently in flight, or `null` when no run
  /// is active.
  ///
  /// Usage recorded while this returns `null` is still attributed to
  /// [agentId] — it simply has no run to join against.
  final String? Function() runIdResolver;

  @override
  AgentScope child(String discriminator) => AgentRunScope(
    conversationId: '$conversationId#$discriminator',
    sessionIdResolver: sessionIdResolver,
    agentId: agentId,
    runIdResolver: runIdResolver,
    channelId: channelId,
    isPrivate: isPrivate,
  );
}

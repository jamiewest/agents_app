// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

/// Casts one configured agent as a named role inside a workflow.
///
/// Workflow builders derive each stage's executor id from the agent's name,
/// so two stages backed by the same saved agent must present distinct names
/// to coexist in one graph. The wrapper also prepends a role instruction to
/// every run, so stages sharing a single underlying model still behave
/// differently.
class RoleAgent extends DelegatingAIAgent {
  /// Wraps [innerAgent] as [role], steered by [roleInstructions].
  RoleAgent(
    super.innerAgent, {
    required this.role,
    required this.roleInstructions,
  });

  /// The stage name; becomes the workflow executor id.
  final String role;

  /// Instructions prepended (as a system message) to every run.
  final String roleInstructions;

  @override
  String get name => role;

  @override
  String? get description => roleInstructions;

  List<ChatMessage> _withRole(Iterable<ChatMessage> messages) => [
    ChatMessage.fromText(ChatRole.system, roleInstructions),
    ...messages,
  ];

  @override
  Future<AgentResponse> runCore(
    Iterable<ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) => innerAgent.runCore(
    _withRole(messages),
    session: session,
    options: options,
    cancellationToken: cancellationToken,
  );

  @override
  Stream<AgentResponseUpdate> runCoreStreaming(
    Iterable<ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) => innerAgent.runCoreStreaming(
    _withRole(messages),
    session: session,
    options: options,
    cancellationToken: cancellationToken,
  );
}

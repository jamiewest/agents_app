// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Mirrors the framework's own test double; its private fields can't use
// initializing formals from named parameters.
// ignore_for_file: prefer_initializing_formals

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';

/// A single assistant message wrapped as an [AgentResponse].
AgentResponse assistantResponse(String text, {String? author}) => AgentResponse(
  messages: [
    ChatMessage(
      role: ChatRole.assistant,
      contents: [TextContent(text)],
      authorName: author,
    ),
  ],
);

/// A deterministic in-memory agent for workflow tests.
class ScriptedAgent extends AIAgent {
  /// Creates a scripted agent; [onRun] and [onStream] script its replies.
  ScriptedAgent({
    String? name,
    AgentResponse Function(
      List<ChatMessage> messages,
      AgentRunOptions? options,
    )?
    onRun,
    List<AgentResponseUpdate> Function(
      List<ChatMessage> messages,
      AgentRunOptions? options,
    )?
    onStream,
  }) : _name = name,
       _onRun = onRun,
       _onStream = onStream;

  final String? _name;
  final AgentResponse Function(
    List<ChatMessage> messages,
    AgentRunOptions? options,
  )?
  _onRun;
  final List<AgentResponseUpdate> Function(
    List<ChatMessage> messages,
    AgentRunOptions? options,
  )?
  _onStream;

  @override
  String? get name => _name;

  @override
  String? get description => null;

  @override
  Future<AgentSession> createSessionCore({
    CancellationToken? cancellationToken,
  }) async => _FakeSession();

  @override
  Future<dynamic> serializeSessionCore(
    AgentSession session, {
    Object? jsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) async => null;

  @override
  Future<AgentSession> deserializeSessionCore(
    dynamic serializedState, {
    Object? jsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) async => _FakeSession();

  @override
  Future<AgentResponse> runCore(
    Iterable<ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    final list = List<ChatMessage>.of(messages);
    return _onRun?.call(list, options) ?? assistantResponse(name ?? 'agent');
  }

  @override
  Stream<AgentResponseUpdate> runCoreStreaming(
    Iterable<ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    final list = List<ChatMessage>.of(messages);
    final updates =
        _onStream?.call(list, options) ??
        (await runCore(
          list,
          session: session,
          options: options,
          cancellationToken: cancellationToken,
        )).toAgentResponseUpdates();
    for (final update in updates) {
      yield update;
    }
  }
}

class _FakeSession extends AgentSession {
  _FakeSession() : super(AgentSessionStateBag(null));
}

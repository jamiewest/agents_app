// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:developer' as developer;

import '../providers/interface/chat_message.dart';

/// The JSON schema version for persisted chat sessions.
const int chatSessionSchemaVersion = 1;

/// A persisted, resumable chat conversation for a single configured agent.
///
/// Holds the visible UI [history] plus the agent's [serializedSession] so a
/// conversation can be restored after a browser restart. API keys are never
/// stored here; they live in the secret store.
class ChatSessionRecord {
  /// Creates a [ChatSessionRecord].
  ChatSessionRecord({
    required this.agentId,
    required this.history,
    required this.createdAt,
    required this.updatedAt,
    this.serializedSession,
  });

  /// The id of the configured agent this conversation belongs to.
  final String agentId;

  /// The visible UI transcript.
  final List<ChatMessage> history;

  /// The agent's serialized session state, when available.
  ///
  /// For agents backed by an in-memory chat history provider this typically
  /// only carries a conversation id; the resumable context comes from
  /// [history]. It is still stored so server-managed conversations can resume.
  final String? serializedSession;

  /// When this conversation was first persisted.
  final DateTime createdAt;

  /// When this conversation was last persisted.
  final DateTime updatedAt;

  /// Reconstructs a record from decoded JSON.
  ///
  /// Returns `null` when the payload is malformed or its schema version is not
  /// understood, so callers can treat it as "no saved conversation".
  static ChatSessionRecord? fromJson(Map<String, dynamic> map) {
    try {
      if (map['version'] != chatSessionSchemaVersion) return null;
      return ChatSessionRecord(
        agentId: map['agentId'] as String,
        history: [
          for (final entry in map['history'] as List<dynamic>)
            ChatMessage.fromJson(entry as Map<String, dynamic>),
        ],
        serializedSession: map['serializedSession'] as String?,
        createdAt: DateTime.parse(map['createdAt'] as String),
        updatedAt: DateTime.parse(map['updatedAt'] as String),
      );
    } catch (e, s) {
      developer.log(
        'Ignoring corrupt chat session record.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  /// Serializes this record to a JSON map.
  ///
  /// Llm placeholder messages with no text are dropped so the stored transcript
  /// stays loadable by [ChatMessage.fromJson].
  Map<String, dynamic> toJson() => {
    'version': chatSessionSchemaVersion,
    'agentId': agentId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (serializedSession != null) 'serializedSession': serializedSession,
    'history': [
      for (final message in history)
        if (_isPersistable(message)) message.toJson(),
    ],
  };

  static bool _isPersistable(ChatMessage message) =>
      message.text != null && message.text!.isNotEmpty;
}

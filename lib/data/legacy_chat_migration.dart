// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;

import '../domain/conversation.dart';
import '../ui/chat_sessions/chat_session_record.dart' as legacy;
import '../ui/chat_sessions/chat_session_store.dart' as legacy;
import 'conversation_store.dart';

/// One-time migration of legacy `KeyValueStore` chat sessions into the
/// durable [RecordStore]-backed conversation model.
///
/// Each legacy record becomes a [Conversation], one [ConversationSession],
/// and transcript messages readable by the chat history provider. Migrated
/// keys are deleted, so re-running is a no-op. Corrupt legacy records are
/// skipped and removed.
class LegacyChatMigration {
  /// Creates a [LegacyChatMigration].
  LegacyChatMigration({required this._keyValueStore, required this._records});

  final KeyValueStore _keyValueStore;
  final RecordStore _records;

  /// Runs the migration.
  Future<void> run() async {
    final keys = await _keyValueStore.keys(
      prefix: legacy.ChatSessionStore.keyPrefix,
    );
    for (final key in keys) {
      try {
        await _migrateKey(key);
      } catch (e, s) {
        developer.log(
          'Failed to migrate legacy chat session "$key"; leaving it in '
          'place.',
          name: 'agents_app.migration',
          error: e,
          stackTrace: s,
        );
      }
    }
  }

  Future<void> _migrateKey(String key) async {
    final raw = await _keyValueStore.read(key);
    if (raw == null) {
      return;
    }

    final record = legacy.ChatSessionRecord.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
    if (record == null) {
      // Corrupt or unknown-schema record: nothing to preserve.
      await _keyValueStore.delete(key);
      return;
    }

    final existing = await _records.get(
      ConversationStore.collection,
      record.id,
    );
    if (existing == null) {
      await _writeConversation(record);
    }
    await _keyValueStore.delete(key);
  }

  Future<void> _writeConversation(legacy.ChatSessionRecord record) async {
    final sessionId = '${record.id}-legacy';
    final conversation = Conversation(
      id: record.id,
      kind: ConversationKind.direct,
      title: record.title,
      titleSource: switch (record.titleSource) {
        legacy.ChatSessionTitleSource.none => ConversationTitleSource.none,
        legacy.ChatSessionTitleSource.firstMessage =>
          ConversationTitleSource.firstMessage,
        legacy.ChatSessionTitleSource.manual => ConversationTitleSource.manual,
        legacy.ChatSessionTitleSource.summary =>
          ConversationTitleSource.summary,
      },
      participantAgentIds: [record.agentId],
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      lastMessagePreview: record.history.isEmpty
          ? null
          : record.history.last.text,
    );
    await _records.put(
      ConversationStore.collection,
      conversation.id,
      conversation.toRecord(),
    );

    final session = ConversationSession(
      id: sessionId,
      conversationId: record.id,
      startedAt: record.createdAt,
      serializedAgentSession: record.serializedSession,
    );
    await _records.put(
      ConversationSessionStore.collection,
      session.id,
      session.toRecord(),
    );

    final createdAt = record.updatedAt.toUtc().toIso8601String();
    var seq = 0;
    for (final message in record.history) {
      final text = message.text;
      if (text == null || text.isEmpty) {
        continue;
      }
      final chatMessage = ai.ChatMessage.fromText(
        message.origin.isUser ? ai.ChatRole.user : ai.ChatRole.assistant,
        text,
      );
      await _records.put(
        ChatMessageRecords.collection,
        '${record.id}-legacy-$seq',
        {
          ChatMessageRecords.conversationIdField: record.id,
          ChatMessageRecords.sessionIdField: sessionId,
          ChatMessageRecords.seqField: seq++,
          if (!message.origin.isUser)
            ChatMessageRecords.senderAgentIdField: record.agentId,
          ChatMessageRecords.createdAtField: createdAt,
          ChatMessageRecords.messageField: ChatMessageCodec.encode(chatMessage),
        },
      );
    }
  }
}

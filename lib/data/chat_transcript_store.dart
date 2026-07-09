// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;

/// One decoded transcript message with its persistence metadata.
class TranscriptEntry {
  /// Creates a [TranscriptEntry].
  const TranscriptEntry({
    required this.seq,
    required this.sessionId,
    required this.message,
    this.senderAgentId,
  });

  /// Per-conversation ordering key.
  final int seq;

  /// The session the message was written under.
  final String sessionId;

  /// The configured agent that produced the message, when known.
  final String? senderAgentId;

  /// The decoded framework message.
  final ai.ChatMessage message;
}

/// Reads the durable conversation transcript written by
/// [FlutterChatHistoryProvider].
class ChatTranscriptStore {
  /// Creates a [ChatTranscriptStore] over [records].
  ChatTranscriptStore(this._records);

  final RecordStore _records;

  /// Loads the transcript of [conversationId] in order.
  Future<List<TranscriptEntry>> load(String conversationId) async {
    final records = await _records.query(
      ChatMessageRecords.collection,
      query: RecordQuery(
        equals: {ChatMessageRecords.conversationIdField: conversationId},
        orderBy: ChatMessageRecords.seqField,
      ),
    );
    return [for (final record in records) ?_decode(record.value)];
  }

  /// Watches the transcript of [conversationId] in order.
  Stream<List<TranscriptEntry>> watch(String conversationId) => _records
      .watch(
        ChatMessageRecords.collection,
        query: RecordQuery(
          equals: {ChatMessageRecords.conversationIdField: conversationId},
          orderBy: ChatMessageRecords.seqField,
        ),
      )
      .map((records) => [for (final record in records) ?_decode(record.value)]);

  /// Deletes the transcript of [conversationId].
  Future<void> deleteFor(String conversationId) => _records.deleteWhere(
    ChatMessageRecords.collection,
    RecordQuery(
      equals: {ChatMessageRecords.conversationIdField: conversationId},
    ),
  );

  /// Replaces the whole stored transcript of [conversationId] with [messages].
  ///
  /// Remote (A2A) agents run inside the paired host's harness, so their turns
  /// never pass through the local [FlutterChatHistoryProvider] that writes the
  /// durable transcript for local agents. For those conversations the app
  /// rewrites the display transcript from the live UI history after each turn.
  /// The write is a full replace — delete then re-insert with fresh 0..n
  /// [seq] — so repeated saves of the same conversation converge on one copy
  /// instead of appending duplicate bubbles. Non-user messages are stamped
  /// with [senderAgentId] when given, matching the provider's schema.
  Future<void> replace({
    required String conversationId,
    required String sessionId,
    required List<ai.ChatMessage> messages,
    String? senderAgentId,
  }) async {
    await deleteFor(conversationId);
    if (messages.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    var seq = 0;
    await _records.putAll(ChatMessageRecords.collection, {
      for (final message in messages)
        _newRecordId(): {
          ChatMessageRecords.conversationIdField: conversationId,
          ChatMessageRecords.sessionIdField: sessionId,
          ChatMessageRecords.seqField: seq++,
          if (message.role != ai.ChatRole.user && senderAgentId != null)
            ChatMessageRecords.senderAgentIdField: senderAgentId,
          ChatMessageRecords.createdAtField: now,
          ChatMessageRecords.messageField: ChatMessageCodec.encode(message),
        },
    });
  }

  static final Random _random = Random.secure();

  static String _newRecordId() {
    final suffix = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  static TranscriptEntry? _decode(Map<String, Object?> record) {
    final encoded = record[ChatMessageRecords.messageField];
    if (encoded is! Map<String, Object?>) {
      return null;
    }
    final message = ChatMessageCodec.decode(encoded);
    if (message == null) {
      return null;
    }
    return TranscriptEntry(
      seq: record[ChatMessageRecords.seqField]! as int,
      sessionId: record[ChatMessageRecords.sessionIdField]! as String,
      senderAgentId: record[ChatMessageRecords.senderAgentIdField] as String?,
      message: message,
    );
  }
}

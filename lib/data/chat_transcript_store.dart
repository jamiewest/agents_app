// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

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

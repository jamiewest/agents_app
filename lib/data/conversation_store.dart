// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

import '../domain/conversation.dart';

String _newId(String prefix) {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}

/// Persists [Conversation] metadata records.
class ConversationStore {
  /// Creates a [ConversationStore] over [records].
  ConversationStore(this._records);

  /// The record collection holding conversations.
  static const String collection = 'conversations';

  final RecordStore _records;

  /// Generates a unique conversation id.
  String newConversationId() => _newId('conv');

  /// Saves [conversation].
  Future<void> save(Conversation conversation) =>
      _records.put(collection, conversation.id, conversation.toRecord());

  /// Loads the conversation with [id], or `null` when missing.
  Future<Conversation?> get(String id) async {
    final record = await _records.get(collection, id);
    return record == null ? null : Conversation.fromRecord(id, record);
  }

  /// Deletes the conversation with [id].
  Future<void> delete(String id) => _records.delete(collection, id);

  /// Archives or unarchives the conversation with [id].
  ///
  /// A no-op when the conversation is missing. The transcript is untouched —
  /// this only moves it in and out of the archived list.
  Future<void> setArchived(String id, bool archived) async {
    final conversation = await get(id);
    if (conversation == null) return;
    await save(conversation.copyWith(archived: archived));
  }

  /// Lists conversations whose primary agent is [agentId], newest first.
  Future<List<Conversation>> listForAgent(String agentId) async {
    final records = await _records.query(
      collection,
      query: RecordQuery(
        equals: {'agentId': agentId},
        orderBy: 'updatedAt',
        descending: true,
      ),
    );
    return [
      for (final record in records)
        Conversation.fromRecord(record.id, record.value),
    ];
  }

  /// Watches the conversations of one channel, newest first.
  Stream<List<Conversation>> watchForChannel(String channelId) => _records
      .watch(
        collection,
        query: RecordQuery(
          equals: {'channelId': channelId},
          orderBy: 'updatedAt',
          descending: true,
        ),
      )
      .map(
        (records) => [
          for (final record in records)
            Conversation.fromRecord(record.id, record.value),
        ],
      );

  /// Watches all conversations, newest first.
  Stream<List<Conversation>> watchAll() => _records
      .watch(
        collection,
        query: const RecordQuery(orderBy: 'updatedAt', descending: true),
      )
      .map(
        (records) => [
          for (final record in records)
            Conversation.fromRecord(record.id, record.value),
        ],
      );

  /// Lists all conversations, newest first.
  Future<List<Conversation>> listAll() async {
    final records = await _records.query(
      collection,
      query: const RecordQuery(orderBy: 'updatedAt', descending: true),
    );
    return [
      for (final record in records)
        Conversation.fromRecord(record.id, record.value),
    ];
  }
}

/// Persists [ConversationSession] records.
class ConversationSessionStore {
  /// Creates a [ConversationSessionStore] over [records].
  ConversationSessionStore(this._records);

  /// The record collection holding sessions.
  static const String collection = 'conversation_sessions';

  final RecordStore _records;

  /// Generates a unique session id.
  String newSessionId() => _newId('sess');

  /// Saves [session].
  Future<void> save(ConversationSession session) =>
      _records.put(collection, session.id, session.toRecord());

  /// Lists the sessions of [conversationId] in start order.
  Future<List<ConversationSession>> listFor(String conversationId) async {
    final records = await _records.query(
      collection,
      query: RecordQuery(
        equals: {'conversationId': conversationId},
        orderBy: 'startedAt',
      ),
    );
    return [
      for (final record in records)
        ConversationSession.fromRecord(record.id, record.value),
    ];
  }

  /// Returns the most recently started session of [conversationId].
  Future<ConversationSession?> latestFor(String conversationId) async {
    final sessions = await listFor(conversationId);
    return sessions.isEmpty ? null : sessions.last;
  }

  /// Deletes every session of [conversationId].
  Future<void> deleteFor(String conversationId) => _records.deleteWhere(
    collection,
    RecordQuery(equals: {'conversationId': conversationId}),
  );
}

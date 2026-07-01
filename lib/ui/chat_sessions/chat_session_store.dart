// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

import 'chat_session_record.dart';

/// Persists resumable chat conversations for configured agents.
///
/// Backed by the already-registered [KeyValueStore], which on Flutter web is
/// browser `localStorage` scoped to the app origin.
class ChatSessionStore {
  /// Creates a [ChatSessionStore] over [store].
  ChatSessionStore(this._store);

  final KeyValueStore _store;

  static final Random _random = Random.secure();

  /// The key prefix under which chat conversations are stored.
  static const String keyPrefix = 'agents_app.chat_conversation.';

  static String _keyFor(String conversationId) => '$keyPrefix$conversationId';

  /// Creates a new app-local conversation id.
  String createConversationId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = _random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
    return 'conversation-$timestamp-$suffix';
  }

  /// Lists saved conversations for [agentId], newest first.
  Future<List<ChatSessionRecord>> list(String agentId) async {
    final keys = await _store.keys(prefix: keyPrefix);
    final conversations = <ChatSessionRecord>[];
    for (final key in keys) {
      final raw = await _store.read(key);
      if (raw == null) continue;
      final record = _decode(raw, key);
      if (record == null || record.agentId != agentId) continue;
      conversations.add(record);
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return conversations;
  }

  /// Loads the saved conversation with [conversationId].
  ///
  /// Returns `null` when nothing is stored or the stored value is corrupt.
  Future<ChatSessionRecord?> load(String conversationId) async {
    final raw = await _store.read(_keyFor(conversationId));
    if (raw == null) return null;
    return _decode(raw, conversationId);
  }

  /// Saves [record], replacing any existing copy of the same conversation.
  Future<void> save(ChatSessionRecord record) =>
      _store.write(_keyFor(record.id), jsonEncode(record.toJson()));

  /// Removes the saved conversation with [conversationId].
  Future<void> delete(String conversationId) =>
      _store.delete(_keyFor(conversationId));

  ChatSessionRecord? _decode(String raw, String key) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ChatSessionRecord.fromJson(map);
    } catch (e, s) {
      developer.log(
        'Ignoring corrupt chat session payload for "$key".',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';

import 'chat_session_record.dart';

/// Persists one resumable chat conversation per configured agent.
///
/// Backed by the already-registered [KeyValueStore], which on Flutter web is
/// browser `localStorage` scoped to the app origin.
class ChatSessionStore {
  /// Creates a [ChatSessionStore] over [store].
  ChatSessionStore(this._store);

  final KeyValueStore _store;

  /// The key prefix under which chat sessions are stored.
  static const String keyPrefix = 'agents_app.chat_session.';

  static String _keyFor(String agentId) => '$keyPrefix$agentId';

  /// Loads the saved conversation for [agentId].
  ///
  /// Returns `null` when nothing is stored or the stored value is corrupt.
  Future<ChatSessionRecord?> load(String agentId) async {
    final raw = await _store.read(_keyFor(agentId));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ChatSessionRecord.fromJson(map);
    } catch (e, s) {
      developer.log(
        'Ignoring corrupt chat session payload for "$agentId".',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  /// Saves [record], replacing any existing conversation for its agent.
  Future<void> save(ChatSessionRecord record) =>
      _store.write(_keyFor(record.agentId), jsonEncode(record.toJson()));

  /// Removes the saved conversation for [agentId].
  Future<void> clear(String agentId) => _store.delete(_keyFor(agentId));
}

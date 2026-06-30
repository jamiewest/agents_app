// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_app/ui/chat_sessions/chat_session_record.dart';
import 'package:agents_app/ui/chat_sessions/chat_session_store.dart';
import 'package:agents_app/ui/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _llmText(String text) =>
    ChatMessage(origin: MessageOrigin.llm, text: text, attachments: const []);

void main() {
  group('ChatSessionStore', () {
    late InMemoryKeyValueStore kv;
    late ChatSessionStore store;

    setUp(() {
      kv = InMemoryKeyValueStore();
      store = ChatSessionStore(kv);
    });

    test('round-trips a saved conversation', () async {
      final created = DateTime.utc(2026, 6, 30, 9);
      final updated = DateTime.utc(2026, 6, 30, 10);
      final record = ChatSessionRecord(
        agentId: 'agent-1',
        history: [ChatMessage.user('hello', const []), _llmText('hi there')],
        serializedSession: '{"conversationId":null}',
        createdAt: created,
        updatedAt: updated,
      );

      await store.save(record);
      final loaded = await store.load('agent-1');

      expect(loaded, isNotNull);
      expect(loaded!.agentId, 'agent-1');
      expect(loaded.serializedSession, '{"conversationId":null}');
      expect(loaded.createdAt, created);
      expect(loaded.updatedAt, updated);
      expect(loaded.history, hasLength(2));
      expect(loaded.history.first.origin, MessageOrigin.user);
      expect(loaded.history.first.text, 'hello');
      expect(loaded.history.last.origin, MessageOrigin.llm);
      expect(loaded.history.last.text, 'hi there');
    });

    test('drops empty llm placeholder messages when saving', () async {
      final record = ChatSessionRecord(
        agentId: 'agent-1',
        history: [
          ChatMessage.user('hello', const []),
          _llmText('answer'),
          ChatMessage.llm(),
        ],
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

      await store.save(record);
      final loaded = await store.load('agent-1');

      expect(loaded!.history, hasLength(2));
      expect(loaded.history.last.text, 'answer');
    });

    test('returns null when nothing is stored', () async {
      expect(await store.load('missing'), isNull);
    });

    test('returns null on corrupt JSON', () async {
      await kv.write('${ChatSessionStore.keyPrefix}agent-1', 'not json{');
      expect(await store.load('agent-1'), isNull);
    });

    test('returns null on an unknown schema version', () async {
      final payload = jsonEncode({
        'version': 99,
        'agentId': 'agent-1',
        'createdAt': DateTime.utc(2026).toIso8601String(),
        'updatedAt': DateTime.utc(2026).toIso8601String(),
        'history': <dynamic>[],
      });
      await kv.write('${ChatSessionStore.keyPrefix}agent-1', payload);
      expect(await store.load('agent-1'), isNull);
    });

    test('isolates conversations per agent', () async {
      await store.save(
        ChatSessionRecord(
          agentId: 'agent-1',
          history: [ChatMessage.user('one', const [])],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );
      await store.save(
        ChatSessionRecord(
          agentId: 'agent-2',
          history: [ChatMessage.user('two', const [])],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      expect((await store.load('agent-1'))!.history.single.text, 'one');
      expect((await store.load('agent-2'))!.history.single.text, 'two');

      await store.clear('agent-1');
      expect(await store.load('agent-1'), isNull);
      expect(await store.load('agent-2'), isNotNull);
    });
  });
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:agents_app/ui/chat_sessions/chat_session_record.dart';
import 'package:agents_app/ui/chat_sessions/chat_session_store.dart';
import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _llmText(String text) =>
    ChatMessage(origin: MessageOrigin.llm, text: text, attachments: const []);

ChatSessionRecord _record({
  required String id,
  required String agentId,
  required String title,
  required DateTime updatedAt,
  List<ChatMessage>? history,
  ChatSessionTitleSource titleSource = ChatSessionTitleSource.firstMessage,
}) => ChatSessionRecord(
  id: id,
  agentId: agentId,
  title: title,
  titleSource: titleSource,
  history: history ?? [ChatMessage.user(title, const [])],
  serializedSession: '{"conversationId":null}',
  createdAt: DateTime.utc(2026, 6, 30, 9),
  updatedAt: updatedAt,
);

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
        id: 'conversation-1',
        agentId: 'agent-1',
        title: 'Planning notes',
        titleSource: ChatSessionTitleSource.manual,
        history: [ChatMessage.user('hello', const []), _llmText('hi there')],
        serializedSession: '{"conversationId":null}',
        createdAt: created,
        updatedAt: updated,
      );

      await store.save(record);
      final loaded = await store.load('conversation-1');

      expect(loaded, isNotNull);
      expect(loaded!.id, 'conversation-1');
      expect(loaded.agentId, 'agent-1');
      expect(loaded.title, 'Planning notes');
      expect(loaded.titleSource, ChatSessionTitleSource.manual);
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
      final record = _record(
        id: 'conversation-1',
        agentId: 'agent-1',
        title: 'hello',
        updatedAt: DateTime.utc(2026),
        history: [
          ChatMessage.user('hello', const []),
          _llmText('answer'),
          ChatMessage.llm(),
        ],
      );

      await store.save(record);
      final loaded = await store.load('conversation-1');

      expect(loaded!.history, hasLength(2));
      expect(loaded.history.last.text, 'answer');
    });

    test('lists conversations for one agent newest first', () async {
      await store.save(
        _record(
          id: 'older',
          agentId: 'agent-1',
          title: 'older',
          updatedAt: DateTime.utc(2026, 6, 30, 9),
        ),
      );
      await store.save(
        _record(
          id: 'other-agent',
          agentId: 'agent-2',
          title: 'other',
          updatedAt: DateTime.utc(2026, 6, 30, 12),
        ),
      );
      await store.save(
        _record(
          id: 'newer',
          agentId: 'agent-1',
          title: 'newer',
          updatedAt: DateTime.utc(2026, 6, 30, 11),
        ),
      );

      final conversations = await store.list('agent-1');

      expect(
        [for (final record in conversations) record.id],
        ['newer', 'older'],
      );
    });

    test('returns null when nothing is stored', () async {
      expect(await store.load('missing'), isNull);
    });

    test('returns null on corrupt JSON', () async {
      await kv.write(
        '${ChatSessionStore.keyPrefix}conversation-1',
        'not json{',
      );
      expect(await store.load('conversation-1'), isNull);
      expect(await store.list('agent-1'), isEmpty);
    });

    test('returns null on an unknown schema version', () async {
      final payload = jsonEncode({
        'version': 99,
        'id': 'conversation-1',
        'agentId': 'agent-1',
        'title': 'Unknown',
        'titleSource': ChatSessionTitleSource.firstMessage.name,
        'createdAt': DateTime.utc(2026).toIso8601String(),
        'updatedAt': DateTime.utc(2026).toIso8601String(),
        'history': <dynamic>[],
      });
      await kv.write('${ChatSessionStore.keyPrefix}conversation-1', payload);
      expect(await store.load('conversation-1'), isNull);
    });

    test('deletes only the selected conversation', () async {
      await store.save(
        _record(
          id: 'conversation-1',
          agentId: 'agent-1',
          title: 'one',
          updatedAt: DateTime.utc(2026),
        ),
      );
      await store.save(
        _record(
          id: 'conversation-2',
          agentId: 'agent-1',
          title: 'two',
          updatedAt: DateTime.utc(2026),
        ),
      );

      await store.delete('conversation-1');

      expect(await store.load('conversation-1'), isNull);
      expect(await store.load('conversation-2'), isNotNull);
    });

    test('ignores old single-session records', () async {
      await kv.write(
        'agents_app.chat_session.agent-1',
        jsonEncode({
          'version': 1,
          'agentId': 'agent-1',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'updatedAt': DateTime.utc(2026).toIso8601String(),
          'history': <dynamic>[],
        }),
      );

      expect(await store.list('agent-1'), isEmpty);
    });

    test('creates unique conversation ids', () {
      final first = store.createConversationId();
      final second = store.createConversationId();

      expect(first, startsWith('conversation-'));
      expect(second, startsWith('conversation-'));
      expect(first, isNot(second));
    });
  });
}

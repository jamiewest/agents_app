import 'dart:convert';

import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/data/legacy_chat_migration.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

/// A real legacy record shape as written by the old ChatSessionStore
/// (schema version 2).
Map<String, Object?> _legacyRecord({
  required String id,
  String agentId = 'agent-1',
  String title = 'Legacy chat',
  String titleSource = 'firstMessage',
  List<Map<String, Object?>>? history,
  String? serializedSession,
}) => {
  'version': 2,
  'id': id,
  'agentId': agentId,
  'title': title,
  'titleSource': titleSource,
  'createdAt': '2026-06-30T09:00:00.000Z',
  'updatedAt': '2026-06-30T10:30:00.000Z',
  'serializedSession': ?serializedSession,
  'history':
      history ??
      [
        {'origin': 'user', 'text': 'hello there', 'attachments': []},
        {'origin': 'llm', 'text': 'hi, how can I help?', 'attachments': []},
      ],
};

void main() {
  late InMemoryKeyValueStore kv;
  late InMemoryRecordStore records;
  late LegacyChatMigration migration;

  setUp(() {
    kv = InMemoryKeyValueStore();
    records = InMemoryRecordStore();
    migration = LegacyChatMigration(keyValueStore: kv, records: records);
  });

  Future<void> seedLegacy(String id, Map<String, Object?> record) =>
      kv.write('agents_app.chat_conversation.$id', jsonEncode(record));

  group('LegacyChatMigration', () {
    test('migrates a legacy record into the conversation model', () async {
      await seedLegacy(
        'conv-legacy-1',
        _legacyRecord(id: 'conv-legacy-1', serializedSession: '{"s":1}'),
      );

      await migration.run();

      final conversation = await ConversationStore(
        records,
      ).get('conv-legacy-1');
      expect(conversation, isNotNull);
      expect(conversation!.kind, ConversationKind.direct);
      expect(conversation.title, 'Legacy chat');
      expect(conversation.titleSource, ConversationTitleSource.firstMessage);
      expect(conversation.participantAgentIds, ['agent-1']);
      expect(conversation.lastMessagePreview, 'hi, how can I help?');

      final sessions = await ConversationSessionStore(
        records,
      ).listFor('conv-legacy-1');
      expect(sessions, hasLength(1));
      expect(sessions.single.serializedAgentSession, '{"s":1}');

      final transcript = await ChatTranscriptStore(
        records,
      ).load('conv-legacy-1');
      expect(transcript.map((e) => e.message.text), [
        'hello there',
        'hi, how can I help?',
      ]);
      expect(transcript.first.message.role, ai.ChatRole.user);
      expect(transcript.last.message.role, ai.ChatRole.assistant);
      expect(transcript.last.senderAgentId, 'agent-1');

      expect(await kv.keys(prefix: 'agents_app.chat_conversation.'), isEmpty);
    });

    test(
      'is idempotent and does not clobber an existing conversation',
      () async {
        await seedLegacy('conv-1', _legacyRecord(id: 'conv-1'));
        await migration.run();

        final store = ConversationStore(records);
        final migrated = await store.get('conv-1');
        await store.save(migrated!.copyWith(title: 'Renamed after migration'));

        // A stale copy of the same legacy key appears again (e.g. restored
        // preferences); running the migration must not overwrite new data.
        await seedLegacy('conv-1', _legacyRecord(id: 'conv-1'));
        await migration.run();

        expect((await store.get('conv-1'))!.title, 'Renamed after migration');
        expect(await kv.keys(prefix: 'agents_app.chat_conversation.'), isEmpty);
      },
    );

    test('drops corrupt legacy records without failing the run', () async {
      await kv.write('agents_app.chat_conversation.bad', 'not json');
      await seedLegacy('conv-good', _legacyRecord(id: 'conv-good'));
      await kv.write(
        'agents_app.chat_conversation.old-schema',
        jsonEncode({'version': 1, 'id': 'old-schema'}),
      );

      await migration.run();

      expect(await ConversationStore(records).get('conv-good'), isNotNull);
      final remaining = await kv.keys(prefix: 'agents_app.chat_conversation.');
      // The unparseable value cannot be decoded as JSON at all and is left
      // in place by the outer error guard; schema-version mismatches are
      // removed.
      expect(remaining, ['agents_app.chat_conversation.bad']);
    });

    test('skips empty-text placeholder messages in the transcript', () async {
      await seedLegacy(
        'conv-2',
        _legacyRecord(
          id: 'conv-2',
          history: [
            {'origin': 'user', 'text': 'question', 'attachments': []},
            {'origin': 'llm', 'text': '', 'attachments': []},
          ],
        ),
      );

      await migration.run();

      final transcript = await ChatTranscriptStore(records).load('conv-2');
      expect(transcript.map((e) => e.message.text), ['question']);
    });
  });

  group('Conversation record round-trip', () {
    test('Conversation survives toRecord/fromRecord', () {
      final conversation = Conversation(
        id: 'c1',
        kind: ConversationKind.group,
        title: 'Team sync',
        titleSource: ConversationTitleSource.manual,
        participantAgentIds: ['a1', 'a2'],
        coordinatorAgentId: 'a1',
        channelId: 'chan-1',
        isPrivate: true,
        createdAt: DateTime.utc(2026, 7, 1, 8),
        updatedAt: DateTime.utc(2026, 7, 2, 9),
        lastMessagePreview: 'see you then',
        hasUnread: true,
      );

      final restored = Conversation.fromRecord('c1', conversation.toRecord());

      expect(restored.kind, ConversationKind.group);
      expect(restored.title, 'Team sync');
      expect(restored.titleSource, ConversationTitleSource.manual);
      expect(restored.participantAgentIds, ['a1', 'a2']);
      expect(restored.coordinatorAgentId, 'a1');
      expect(restored.channelId, 'chan-1');
      expect(restored.isPrivate, isTrue);
      expect(restored.createdAt, DateTime.utc(2026, 7, 1, 8));
      expect(restored.updatedAt, DateTime.utc(2026, 7, 2, 9));
      expect(restored.lastMessagePreview, 'see you then');
      expect(restored.hasUnread, isTrue);
      // Absent marker restores as read, and copyWith preserves updatedAt so
      // clearing on open never reorders the list.
      final cleared = restored.copyWith(hasUnread: false);
      expect(
        Conversation.fromRecord('c1', cleared.toRecord()).hasUnread,
        false,
      );
      expect(cleared.updatedAt, DateTime.utc(2026, 7, 2, 9));
    });

    test('ConversationSession survives toRecord/fromRecord', () {
      final session = ConversationSession(
        id: 's1',
        conversationId: 'c1',
        startedAt: DateTime.utc(2026, 7, 1, 8),
        endedAt: DateTime.utc(2026, 7, 1, 9),
        serializedAgentSession: '{"x":true}',
      );

      final restored = ConversationSession.fromRecord('s1', session.toRecord());

      expect(restored.conversationId, 'c1');
      expect(restored.startedAt, DateTime.utc(2026, 7, 1, 8));
      expect(restored.endedAt, DateTime.utc(2026, 7, 1, 9));
      expect(restored.serializedAgentSession, '{"x":true}');
    });
  });
}

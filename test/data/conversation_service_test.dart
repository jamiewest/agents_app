import 'package:agents_app/data/conversation_service.dart';
import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _direct() => Conversation(
  id: 'c-direct',
  kind: ConversationKind.direct,
  title: 'Original',
  titleSource: ConversationTitleSource.firstMessage,
  participantAgentIds: const ['a1'],
  createdAt: DateTime.utc(2026, 7, 1),
  updatedAt: DateTime.utc(2026, 7, 1),
);

void main() {
  late InMemoryRecordStore records;
  late ConversationStore store;
  late ConversationService service;

  setUp(() {
    records = InMemoryRecordStore();
    store = ConversationStore(records);
    service = ConversationService(store);
  });

  group('ConversationService.createGroupFromDirect', () {
    test('creates a group and leaves the original untouched', () async {
      final original = _direct();
      await store.save(original);

      final group = await service.createGroupFromDirect(
        original: original,
        addedAgentIds: ['a2', 'a1'],
        coordinatorAgentId: 'a1',
        agentNamesById: {'a1': 'Alice', 'a2': 'Bob'},
      );

      expect(group.id, isNot(original.id));
      expect(group.kind, ConversationKind.group);
      expect(group.participantAgentIds, ['a1', 'a2']);
      expect(group.coordinatorAgentId, 'a1');
      expect(group.title, 'Alice, Bob');
      expect(group.titleSource, ConversationTitleSource.summary);

      final storedOriginal = await store.get(original.id);
      expect(storedOriginal!.kind, ConversationKind.direct);
      expect(storedOriginal.participantAgentIds, ['a1']);
      expect(await store.get(group.id), isNotNull);
    });

    test('requires the coordinator to be a participant', () async {
      expect(
        () => service.createGroupFromDirect(
          original: _direct(),
          addedAgentIds: ['a2'],
          coordinatorAgentId: 'outsider',
          agentNamesById: const {},
        ),
        throwsArgumentError,
      );
    });
  });
}

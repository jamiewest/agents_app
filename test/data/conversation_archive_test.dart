// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conversation({bool archived = false}) => Conversation(
  id: 'c1',
  kind: ConversationKind.direct,
  title: 'Chat',
  titleSource: ConversationTitleSource.firstMessage,
  participantAgentIds: const ['a1'],
  createdAt: DateTime.utc(2026, 7, 1),
  updatedAt: DateTime.utc(2026, 7, 1),
  archived: archived,
);

void main() {
  group('Conversation.archived', () {
    test('defaults to false and survives a record round-trip', () {
      expect(_conversation().archived, isFalse);

      final restored = Conversation.fromRecord(
        'c1',
        _conversation(archived: true).toRecord(),
      );
      expect(restored.archived, isTrue);
    });

    test('an unarchived conversation writes no archived flag', () {
      expect(_conversation().toRecord().containsKey('archived'), isFalse);
    });

    test('copyWith toggles the flag without touching other fields', () {
      final archived = _conversation().copyWith(archived: true);
      expect(archived.archived, isTrue);
      expect(archived.title, 'Chat');

      expect(archived.copyWith(archived: false).archived, isFalse);
    });
  });

  group('ConversationStore.setArchived', () {
    late ConversationStore store;

    setUp(() => store = ConversationStore(InMemoryRecordStore()));

    test('archives and unarchives an existing conversation', () async {
      await store.save(_conversation());

      await store.setArchived('c1', true);
      expect((await store.get('c1'))!.archived, isTrue);

      await store.setArchived('c1', false);
      expect((await store.get('c1'))!.archived, isFalse);
    });

    test('is a no-op for a missing conversation', () async {
      await store.setArchived('ghost', true);
      expect(await store.get('ghost'), isNull);
    });
  });
}

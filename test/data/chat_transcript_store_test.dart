// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/chat_transcript_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

void main() {
  ai.ChatMessage user(String text) =>
      ai.ChatMessage(role: ai.ChatRole.user, contents: [ai.TextContent(text)]);

  ai.ChatMessage assistant(String text) => ai.ChatMessage(
    role: ai.ChatRole.assistant,
    contents: [ai.TextContent(text)],
  );

  group('ChatTranscriptStore.replace', () {
    test('round-trips messages back through load in order', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());

      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('hello'), assistant('hi there')],
      );

      final entries = await store.load('conv-1');
      expect(entries.map((e) => e.message.text), ['hello', 'hi there']);
      expect(entries.map((e) => e.seq), [0, 1]);
      expect(entries.every((e) => e.sessionId == 'sess-1'), isTrue);
    });

    test('is idempotent: re-saving the same turns keeps one copy', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());
      final messages = [user('hello'), assistant('hi there')];

      // The change listener fires several times around a turn; each fire is a
      // full replace, so repeated saves must converge, not accumulate.
      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: messages,
      );
      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: messages,
      );

      final entries = await store.load('conv-1');
      expect(entries.map((e) => e.message.text), ['hello', 'hi there']);
    });

    test('grows cleanly as a conversation gains turns', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());

      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('one'), assistant('two')],
      );
      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('one'), assistant('two'), user('three')],
      );

      final entries = await store.load('conv-1');
      expect(entries.map((e) => e.message.text), ['one', 'two', 'three']);
      expect(entries.map((e) => e.seq), [0, 1, 2]);
    });

    test('stamps senderAgentId on non-user messages only', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());

      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('hello'), assistant('hi there')],
        senderAgentId: 'agent-1',
      );

      final entries = await store.load('conv-1');
      expect(entries[0].senderAgentId, isNull);
      expect(entries[1].senderAgentId, 'agent-1');
    });

    test('an empty message list clears the transcript', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());
      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('hello')],
      );

      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: const [],
      );

      expect(await store.load('conv-1'), isEmpty);
    });

    test('does not disturb another conversation', () async {
      final store = ChatTranscriptStore(InMemoryRecordStore());
      await store.replace(
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messages: [user('keep me')],
      );

      await store.replace(
        conversationId: 'conv-2',
        sessionId: 'sess-2',
        messages: [user('other')],
      );

      expect((await store.load('conv-1')).map((e) => e.message.text), [
        'keep me',
      ]);
      expect((await store.load('conv-2')).map((e) => e.message.text), [
        'other',
      ]);
    });
  });
}

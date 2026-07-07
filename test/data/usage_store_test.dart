// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/usage_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatUsageRecord record({
    String conversationId = 'conv-1',
    String sessionId = 'session-1',
    String modelId = 'model-a',
    String provider = 'anthropic',
    int input = 10,
    int output = 5,
    int? cached,
    int? reasoning,
    DateTime? timestamp,
  }) => ChatUsageRecord(
    timestamp: timestamp ?? DateTime.utc(2026, 7, 6, 12),
    conversationId: conversationId,
    sessionId: sessionId,
    modelId: modelId,
    sourceId: 'source-1',
    provider: provider,
    inputTokenCount: input,
    outputTokenCount: output,
    totalTokenCount: input + output,
    cachedInputTokenCount: cached,
    reasoningTokenCount: reasoning,
  );

  // record() writes fire-and-forget; settle pending microtasks/futures.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('UsageStore', () {
    test('records and lists usage per conversation in call order', () async {
      final store = UsageStore(InMemoryRecordStore());

      store.record(
        record(input: 10, timestamp: DateTime.utc(2026, 7, 6, 12, 0)),
      );
      store.record(
        record(input: 20, timestamp: DateTime.utc(2026, 7, 6, 12, 1)),
      );
      store.record(record(conversationId: 'conv-other', input: 99));
      await settle();

      final listed = await store.listFor('conv-1');
      expect(listed, hasLength(2));
      expect(listed.first.inputTokenCount, 10);
      expect(listed.last.inputTokenCount, 20);
      expect(listed.first.modelId, 'model-a');
      expect(listed.first.provider, 'anthropic');
      expect(listed.first.sessionId, 'session-1');
    });

    test('round-trips nullable counts', () async {
      final store = UsageStore(InMemoryRecordStore());

      store.record(record(cached: 80, reasoning: 12));
      await settle();

      final loaded = (await store.listFor('conv-1')).single;
      expect(loaded.cachedInputTokenCount, 80);
      expect(loaded.reasoningTokenCount, 12);
      expect(loaded.totalTokenCount, 15);
    });

    test('watchFor emits on new records', () async {
      final store = UsageStore(InMemoryRecordStore());
      final emissions = <List<ChatUsageRecord>>[];
      final sub = store.watchFor('conv-1').listen(emissions.add);
      await settle();

      store.record(record());
      await settle();

      await sub.cancel();
      expect(emissions.last, hasLength(1));
    });

    test('deleteFor removes only that conversation', () async {
      final store = UsageStore(InMemoryRecordStore());
      store.record(record());
      store.record(record(conversationId: 'conv-2'));
      await settle();

      await store.deleteFor('conv-1');

      expect(await store.listFor('conv-1'), isEmpty);
      expect(await store.listFor('conv-2'), hasLength(1));
    });

    test('totalsByModel groups and sums, optionally by session', () {
      final records = [
        record(modelId: 'model-a', input: 10, output: 5, cached: 4),
        record(modelId: 'model-a', input: 20, output: 10),
        record(modelId: 'model-b', provider: 'localLlama', input: 7, output: 3),
        record(modelId: 'model-a', sessionId: 'session-2', input: 100),
      ];

      final all = UsageStore.totalsByModel(records);
      expect(all, hasLength(2));
      expect(all['model-a']!.calls, 3);
      expect(all['model-a']!.inputTokens, 130);
      expect(all['model-a']!.outputTokens, 20);
      expect(all['model-a']!.cachedTokens, 4);
      expect(all['model-b']!.provider, 'localLlama');
      expect(all['model-b']!.inputTokens, 7);

      final session1 = UsageStore.totalsByModel(
        records,
        sessionId: 'session-1',
      );
      expect(session1['model-a']!.calls, 2);
      expect(session1['model-a']!.inputTokens, 30);
    });
  });
}

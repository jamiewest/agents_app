// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_run_scope.dart';
import 'package:agents_app/data/prompt_log.dart';
import 'package:agents_app/data/prompt_logging.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/system.dart' show CancellationToken;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = ModelSourceConfig(
    id: 'source-1',
    providerType: ProviderType.localLlama,
    displayName: 'Local',
  );
  const model = ModelConfig(
    id: 'model-1',
    sourceId: 'source-1',
    modelId: 'fake-model',
  );

  AgentRunScope scope({
    String agentId = 'agent-1',
    required String? Function() runId,
    bool isPrivate = false,
  }) => AgentRunScope(
    conversationId: 'conv-1',
    sessionIdResolver: () => 'session-1',
    agentId: agentId,
    runIdResolver: runId,
    isPrivate: isPrivate,
  );

  LoggingConfiguredChatClientFactory factory(UsageRecordSink sink) =>
      LoggingConfiguredChatClientFactory(
        log: PromptLog(),
        usageSink: sink,
        customClientResolver: ({required source, required model, httpClient}) =>
            _UsageEmittingChatClient(),
      );

  Future<void> callOnce(ai.ChatClient client) => client
      .getStreamingResponse(
        messages: [ai.ChatMessage.fromText(ai.ChatRole.user, 'hi')],
      )
      .drain<void>();

  // Usage records are written fire-and-forget; settle pending futures.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('AgentRunScope', () {
    test('carries the agent id and resolves the run id lazily', () {
      var current = 'run-a';
      final runScope = scope(runId: () => current);

      expect(runScope.agentId, 'agent-1');
      expect(runScope.runIdResolver(), 'run-a');
      current = 'run-b';
      expect(runScope.runIdResolver(), 'run-b');
    });

    test('child scopes keep the initiating agent and run', () {
      // The package derives delegate scopes through this one call
      // (configured_agent_factory.dart), so overriding it is what makes
      // delegated model calls roll up to the agent the user invoked.
      final runScope = scope(runId: () => 'run-a');

      final delegate = runScope.child('delegate-summarize');

      expect(delegate, isA<AgentRunScope>());
      final child = delegate as AgentRunScope;
      expect(child.agentId, 'agent-1');
      expect(child.runIdResolver(), 'run-a');
      expect(child.conversationId, 'conv-1#delegate-summarize');
      expect(child.isPrivate, isFalse);
    });

    test('child scopes inherit privacy', () {
      final runScope = scope(runId: () => 'run-a', isPrivate: true);

      expect((runScope.child('delegate-x') as AgentRunScope).isPrivate, isTrue);
    });
  });

  group('usage attribution', () {
    test('stamps the agent and run onto each usage record', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => 'run-a'),
      );

      await callOnce(client);
      await settle();

      final totals = await store.totalsForRun('run-a');
      expect(totals.calls, 1);
      expect(totals.inputTokens, 12);
      expect(totals.outputTokens, 6);
      expect(totals.totalTokens, 18);
    });

    test('one scope attributes successive turns to different runs', () async {
      // A chat scope is built once when the conversation opens and then
      // serves every turn, so the run id must be read at write time.
      final store = UsageStore(InMemoryRecordStore());
      String? current = 'run-a';
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => current),
      );

      await callOnce(client);
      current = 'run-b';
      await callOnce(client);
      await settle();

      expect((await store.totalsForRun('run-a')).calls, 1);
      expect((await store.totalsForRun('run-b')).calls, 1);
    });

    test(
      'concurrent runs in one conversation do not cross-attribute',
      () async {
        final store = UsageStore(InMemoryRecordStore());
        final clientA = factory(store).createChatClient(
          source: source,
          model: model,
          scope: scope(agentId: 'agent-1', runId: () => 'run-a'),
        );
        final clientB = factory(store).createChatClient(
          source: source,
          model: model,
          scope: scope(agentId: 'agent-2', runId: () => 'run-b'),
        );

        await Future.wait([callOnce(clientA), callOnce(clientB)]);
        await settle();

        expect((await store.totalsForRun('run-a')).calls, 1);
        expect((await store.totalsForRun('run-b')).calls, 1);
        final byAgent = await store.totalsByAgent();
        expect(byAgent['agent-1']!.totalTokens, 18);
        expect(byAgent['agent-2']!.totalTokens, 18);
      },
    );

    test('sums every model call of a run, tool-loop calls included', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => 'run-a'),
      );

      await callOnce(client);
      await callOnce(client);
      await callOnce(client);
      await settle();

      final totals = await store.totalsForRun('run-a');
      expect(totals.calls, 3);
      expect(totals.inputTokens, 36);
      expect(totals.outputTokens, 18);
    });

    test('attributes usage recorded outside a run to the agent only', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => null),
      );

      await callOnce(client);
      await settle();

      expect((await store.totalsByAgent())['agent-1']!.calls, 1);
      expect((await store.totalsForRun('run-a')).calls, 0);
    });

    test('private scopes persist nothing', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => 'run-a', isPrivate: true),
      );

      await callOnce(client);
      await settle();

      expect(await store.listFor('conv-1'), isEmpty);
      expect(await store.totalsByAgent(), isEmpty);
    });

    test('scope-less calls record usage but no agent', () async {
      // Hosting internals and the title summarizer have no agent to bill.
      // Their rows must not skew per-agent rollups.
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(
        store,
      ).createChatClient(source: source, model: model);

      await callOnce(client);
      await settle();

      expect(await store.totalsByAgent(), isEmpty);
    });

    test('a plain AgentScope still records unattributed usage', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: AgentScope(
          conversationId: 'conv-1',
          sessionIdResolver: () => 'session-1',
        ),
      );

      await callOnce(client);
      await settle();

      expect(await store.listFor('conv-1'), hasLength(1));
      expect(await store.totalsByAgent(), isEmpty);
    });

    test('totalsByAgent honours a time cutoff', () async {
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => 'run-a'),
      );

      await callOnce(client);
      await settle();

      final future = DateTime.now().add(const Duration(days: 1));
      expect(await store.totalsByAgent(since: future), isEmpty);
      final past = DateTime.now().subtract(const Duration(days: 1));
      expect((await store.totalsByAgent(since: past))['agent-1']!.calls, 1);
    });

    test('run totals agree with the per-conversation ledger the usage sheet '
        'reads', () async {
      // The regression that would appear if run tokens were accumulated
      // separately instead of joined: two totals for the same calls.
      final store = UsageStore(InMemoryRecordStore());
      final client = factory(store).createChatClient(
        source: source,
        model: model,
        scope: scope(runId: () => 'run-a'),
      );

      await callOnce(client);
      await callOnce(client);
      await settle();

      final run = await store.totalsForRun('run-a');
      final byModel = UsageStore.totalsByModel(await store.listFor('conv-1'));
      expect(run.calls, byModel['fake-model']!.calls);
      expect(run.inputTokens, byModel['fake-model']!.inputTokens);
      expect(run.outputTokens, byModel['fake-model']!.outputTokens);
    });
  });
}

/// A fake provider client whose streaming update reports usage, the way
/// cloud clients and the llama runtime do.
final class _UsageEmittingChatClient implements ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse.fromMessage(
    ai.ChatMessage.fromText(ai.ChatRole.assistant, 'hi'),
  )..usage = ai.UsageDetails(inputTokenCount: 12, outputTokenCount: 6);

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => Stream.fromIterable([
    ai.ChatResponseUpdate(
      role: ai.ChatRole.assistant,
      contents: [ai.TextContent('hi')],
      usage: ai.UsageDetails(inputTokenCount: 12, outputTokenCount: 6),
    ),
  ]);

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

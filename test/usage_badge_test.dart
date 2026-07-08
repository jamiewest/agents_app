// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/usage_store.dart';
import 'package:agents_app/ui/chat_view_model/chat_view_model.dart';
import 'package:agents_app/ui/chat_view_model/chat_view_model_provider.dart';
import 'package:agents_app/ui/providers/interface/attachments.dart';
import 'package:agents_app/ui/providers/interface/chat_message.dart';
import 'package:agents_app/ui/providers/interface/llm_provider.dart';
import 'package:agents_app/ui/providers/interface/message_origin.dart';
import 'package:agents_app/ui/views/chat_message_view/llm_message_view.dart';
import 'package:agents_app/ui/widgets/usage_stats_sheet.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('usageSummaryText', () {
    test('formats in/out with separators', () {
      final text = usageSummaryText(
        ai.UsageDetails(inputTokenCount: 12345, outputTokenCount: 678),
      );
      expect(text, '▲ 12,345  ▼ 678');
    });

    test('appends cached and reasoning only when positive', () {
      final text = usageSummaryText(
        ai.UsageDetails(
          inputTokenCount: 100,
          outputTokenCount: 20,
          cachedInputTokenCount: 80,
          reasoningTokenCount: 5,
        ),
      );
      expect(text, '▲ 100  ▼ 20 · 80 cached · 5 reasoning');

      final noExtras = usageSummaryText(
        ai.UsageDetails(
          inputTokenCount: 100,
          outputTokenCount: 20,
          cachedInputTokenCount: 0,
        ),
      );
      expect(noExtras, '▲ 100  ▼ 20');
    });
  });

  test('formatTokenCount groups thousands', () {
    expect(formatTokenCount(0), '0');
    expect(formatTokenCount(999), '999');
    expect(formatTokenCount(1000), '1,000');
    expect(formatTokenCount(1234567), '1,234,567');
  });

  test('formatTurnDuration scales with magnitude', () {
    expect(formatTurnDuration(const Duration(milliseconds: 840)), '0.8s');
    expect(
      formatTurnDuration(const Duration(seconds: 9, milliseconds: 940)),
      '9.9s',
    );
    expect(formatTurnDuration(const Duration(seconds: 12)), '12s');
    expect(
      formatTurnDuration(const Duration(minutes: 2, seconds: 5)),
      '2m 05s',
    );
  });

  group('liveTurnStatusText', () {
    final startedAt = DateTime(2026, 7, 7, 12);
    final now = startedAt.add(const Duration(seconds: 7));

    test('shows Thinking with elapsed time before any text', () {
      final message = ChatMessage.llm()..turnStartedAt = startedAt;
      expect(liveTurnStatusText(message, now: now), 'Thinking… · 7s');
    });

    test('shows Writing plus tokens once text and usage arrive', () {
      final message = ChatMessage.llm()
        ..append('Partial answer')
        ..turnStartedAt = startedAt
        ..usage = ai.UsageDetails(inputTokenCount: 1234, outputTokenCount: 56);
      expect(
        liveTurnStatusText(message, now: now),
        'Writing… · 7s · ▲ 1,234  ▼ 56',
      );
    });

    test('shows the running tool over Thinking/Writing', () {
      final message = ChatMessage.llm()
        ..turnStartedAt = startedAt
        ..toolActivity = 'search, fetch';
      expect(
        liveTurnStatusText(message, now: now),
        'Running search, fetch… · 7s',
      );
    });
  });

  testWidgets('LlmMessageView shows a badge for a message with usage', (
    tester,
  ) async {
    final message = ChatMessage(
      origin: MessageOrigin.llm,
      text: 'The answer.',
      attachments: const [],
    )..usage = ai.UsageDetails(inputTokenCount: 1234, outputTokenCount: 56);

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.text('▲ 1,234  ▼ 56'), findsOneWidget);
  });

  testWidgets('LlmMessageView appends the turn duration when known', (
    tester,
  ) async {
    final message =
        ChatMessage(
            origin: MessageOrigin.llm,
            text: 'The answer.',
            attachments: const [],
          )
          ..usage = ai.UsageDetails(inputTokenCount: 1234, outputTokenCount: 56)
          ..turnDuration = const Duration(seconds: 12);

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.text('▲ 1,234  ▼ 56 · 12s'), findsOneWidget);
  });

  testWidgets('LlmMessageView shows the live status line while generating', (
    tester,
  ) async {
    final message = ChatMessage.llm()
      ..isGenerating = true
      ..turnStartedAt = DateTime.now();

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(LiveTurnStatus), findsOneWidget);
    expect(find.textContaining('Thinking…'), findsOneWidget);
    expect(find.byType(UsageBadge), findsNothing);

    // Unmount to cancel the status line's ticking timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('LlmMessageView shows no badge without usage', (tester) async {
    final message = ChatMessage(
      origin: MessageOrigin.llm,
      text: 'The answer.',
      attachments: const [],
    );

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(UsageBadge), findsNothing);
  });

  testWidgets('UsageStatsSheet groups totals by model and session', (
    tester,
  ) async {
    final store = UsageStore(InMemoryRecordStore());
    ChatUsageRecord record({
      required String modelId,
      required String sessionId,
      required int input,
      required int output,
    }) => ChatUsageRecord(
      timestamp: DateTime.utc(2026, 7, 6),
      conversationId: 'conv-1',
      sessionId: sessionId,
      modelId: modelId,
      sourceId: 'source-1',
      provider: 'anthropic',
      inputTokenCount: input,
      outputTokenCount: output,
    );
    store
      ..record(
        record(modelId: 'claude-x', sessionId: 's1', input: 100, output: 10),
      )
      ..record(
        record(modelId: 'claude-x', sessionId: 's2', input: 200, output: 20),
      )
      ..record(
        record(modelId: 'gemma-y', sessionId: 's2', input: 50, output: 5),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UsageStatsSheet(
            usage: store,
            conversationId: 'conv-1',
            currentSessionId: 's2',
          ),
        ),
      ),
    );
    // First pump delivers the watch stream's initial emission.
    await tester.pump();
    await tester.pump();

    expect(find.text('Current session'), findsOneWidget);
    expect(find.text('Whole conversation'), findsOneWidget);
    // Session section: only s2 records; conversation section: both models.
    expect(find.text('▲ 200 in · ▼ 20 out'), findsOneWidget);
    expect(find.text('▲ 300 in · ▼ 30 out'), findsOneWidget);
    expect(find.text('▲ 50 in · ▼ 5 out'), findsNWidgets(2));
    expect(find.text('claude-x'), findsNWidgets(2));
    expect(find.text('gemma-y'), findsNWidgets(2));
  });
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: ChatViewModelProvider(
      viewModel: ChatViewModel(
        provider: _FakeLlmProvider(),
        style: null,
        suggestions: const [],
        welcomeMessage: null,
        responseBuilder: null,
        messageSender: null,
        onMessageSubmitted: null,
        speechToText: null,
        enableAttachments: false,
        enableVoiceNotes: false,
      ),
      child: child,
    ),
  ),
);

final class _FakeLlmProvider extends LlmProvider with ChangeNotifier {
  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) => const Stream.empty();

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) => const Stream.empty();

  @override
  Iterable<ChatMessage> get history => const [];

  @override
  set history(Iterable<ChatMessage> history) {}
}

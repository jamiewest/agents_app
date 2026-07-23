import 'dart:typed_data';

import 'package:agents_app/data/prompt_log.dart';
import 'package:agents_app/data/prompt_logging.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/chat.dart' show PromptSnapshot;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/system.dart' show CancellationToken;
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_test_harness.dart' show EchoChatClient;

void main() {
  group('LoggingConfiguredChatClientFactory usage tracking', () {
    const llamaSource = ModelSourceConfig(
      id: 'source-1',
      providerType: ProviderType.localLlama,
      displayName: 'Local',
    );
    const model = ModelConfig(
      id: 'model-1',
      sourceId: 'source-1',
      modelId: 'fake-model',
    );
    AgentScope scope({bool isPrivate = false}) => AgentScope(
      conversationId: 'conv-1',
      sessionIdResolver: () => 'session-1',
      isPrivate: isPrivate,
    );

    LoggingConfiguredChatClientFactory factory(UsageRecordSink sink) =>
        LoggingConfiguredChatClientFactory(
          log: PromptLog(),
          usageSink: sink,
          customClientResolver:
              ({required source, required model, httpClient}) =>
                  _UsageEmittingChatClient(),
        );

    test('wraps local llama clients and records attributed usage', () async {
      final sink = _RecordingSink();
      final client = factory(
        sink,
      ).createChatClient(source: llamaSource, model: model, scope: scope());

      expect(client, isA<UsageTrackingChatClient>());
      await client
          .getStreamingResponse(
            messages: [ai.ChatMessage.fromText(ai.ChatRole.user, 'hi')],
          )
          .drain<void>();

      final record = sink.records.single;
      expect(record.modelId, 'fake-model');
      expect(record.sourceId, 'source-1');
      expect(record.provider, 'localLlama');
      expect(record.conversationId, 'conv-1');
      expect(record.sessionId, 'session-1');
      expect(record.inputTokenCount, 12);
      expect(record.outputTokenCount, 6);
    });

    test('private scopes keep badges but skip the ledger', () async {
      final sink = _RecordingSink();
      final client = factory(sink).createChatClient(
        source: llamaSource,
        model: model,
        scope: scope(isPrivate: true),
      );

      final updates = await client
          .getStreamingResponse(
            messages: [ai.ChatMessage.fromText(ai.ChatRole.user, 'hi')],
          )
          .toList();

      expect(sink.records, isEmpty);
      expect(
        updates.any((u) => u.contents.any((c) => c is ai.UsageContent)),
        isTrue,
      );
    });

    test('leaves clients unwrapped without a usage sink', () {
      final noSink = LoggingConfiguredChatClientFactory(
        log: PromptLog(),
        customClientResolver: ({required source, required model, httpClient}) =>
            _UsageEmittingChatClient(),
      );

      final client = noSink.createChatClient(
        source: llamaSource,
        model: model,
        scope: scope(),
      );

      expect(client, isNot(isA<UsageTrackingChatClient>()));
    });
  });

  group('LoggingChatClient', () {
    test(
      'records one entry per streaming request with title and body',
      () async {
        final log = PromptLog();
        final client = LoggingChatClient(
          EchoChatClient(),
          log: log,
          title: 'anthropic · claude-x',
        );

        await client
            .getStreamingResponse(
              messages: <ai.ChatMessage>[
                ai.ChatMessage.fromText(ai.ChatRole.user, 'hi'),
              ],
              options: ai.ChatOptions()..instructions = 'You are helpful.',
            )
            .drain<void>();

        expect(log.entries, hasLength(1));
        final entry = log.entries.single;
        expect(entry.title, 'anthropic · claude-x');
        expect(entry.body, contains('You are helpful.'));
        expect(entry.body, contains('[user]'));
        expect(entry.body, contains('hi'));
      },
    );

    test(
      'records one entry per getResponse request (no double-logging)',
      () async {
        final log = PromptLog();
        final client = LoggingChatClient(
          EchoChatClient(),
          log: log,
          title: 'openAiCompatible · gpt',
        );

        await client.getResponse(
          messages: <ai.ChatMessage>[
            ai.ChatMessage.fromText(ai.ChatRole.user, 'hello'),
          ],
        );

        expect(log.entries, hasLength(1));
      },
    );
  });

  group('renderRequest', () {
    test('renders instructions, tools, and message content markers', () {
      final messages = <ai.ChatMessage>[
        ai.ChatMessage.fromText(ai.ChatRole.user, 'look at this'),
        ai.ChatMessage(
          role: ai.ChatRole.assistant,
          contents: <ai.AIContent>[
            ai.FunctionCallContent(
              callId: 'c1',
              name: 'getWeather',
              arguments: const <String, Object?>{'city': 'Paris'},
            ),
          ],
        ),
        ai.ChatMessage(
          role: ai.ChatRole.tool,
          contents: <ai.AIContent>[
            ai.FunctionResultContent(callId: 'c1', result: 'sunny'),
          ],
        ),
        ai.ChatMessage(
          role: ai.ChatRole.user,
          contents: <ai.AIContent>[
            ai.DataContent(
              Uint8List.fromList(<int>[1, 2, 3]),
              mediaType: 'image/png',
            ),
          ],
        ),
      ];
      final options = ai.ChatOptions()
        ..instructions = 'Be terse.'
        ..tools = <ai.AITool>[
          ai.AIFunctionFactory.create(
            name: 'getWeather',
            description: 'weather',
            callback:
                (arguments, {CancellationToken? cancellationToken}) async =>
                    'sunny',
          ),
        ];

      final rendered = renderRequest(messages, options);

      expect(rendered, contains('[system instructions]'));
      expect(rendered, contains('Be terse.'));
      expect(rendered, contains('[tools] getWeather'));
      expect(rendered, contains('(tool call getWeather {"city":"Paris"})'));
      expect(rendered, contains('(tool result c1: sunny)'));
      expect(rendered, contains('(image)'));
    });
  });

  group('PromptLogInspector', () {
    test('mirrors the wire snapshot and sampling tags into the log', () {
      final log = PromptLog();
      final inspector = PromptLogInspector(log);

      inspector.record(
        PromptSnapshot(
          text: '<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n',
          stopSequences: const <String>['<|im_end|>'],
          maxTokens: 256,
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
          seed: 1,
          imageCount: 0,
          contextSize: 4096,
          capturedAt: DateTime(2026),
        ),
      );

      expect(log.entries, hasLength(1));
      final entry = log.entries.single;
      expect(entry.title, 'local llama');
      expect(entry.body, contains('<|im_start|>user'));
      expect(entry.tags, contains('temp 0.7'));
      expect(entry.tags, contains('4096 ctx'));
      expect(entry.tags, contains('stop <|im_end|>'));
      // The base inspector still exposes the latest snapshot.
      expect(inspector.latest?.text, contains('hi'));
    });
  });
}

final class _RecordingSink implements UsageRecordSink {
  final List<ChatUsageRecord> records = [];

  @override
  void record(ChatUsageRecord record) => records.add(record);
}

/// A fake provider client whose final streaming update reports usage, the
/// way cloud clients and the llama runtime do.
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

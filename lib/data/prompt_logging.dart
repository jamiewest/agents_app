import 'dart:convert';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_llama/agents_llama.dart' show PromptInspector,
    PromptSnapshot;
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:http/http.dart' as http;

import 'prompt_log.dart';

/// A [ConfiguredChatClientFactory] that captures every prompt it produces.
///
/// Wraps each cloud provider's client in a [LoggingChatClient] so the request
/// (system instructions, declared tools, and message history) lands in [log].
/// Local llama clients already capture their exact wire-format prompt through
/// the shared [PromptInspector], so they are returned unwrapped to avoid
/// logging the same turn twice.
class LoggingConfiguredChatClientFactory extends ConfiguredChatClientFactory {
  /// Creates a factory that records prompts into [log].
  LoggingConfiguredChatClientFactory({
    required this.log,
    super.isWeb,
    super.customClientResolver,
  });

  /// The unified prompt log every produced client writes to.
  final PromptLog log;

  @override
  ChatClient createChatClient({
    required ModelSourceConfig source,
    required ModelConfig model,
    String? apiKey,
    http.Client? httpClient,
  }) {
    final inner = super.createChatClient(
      source: source,
      model: model,
      apiKey: apiKey,
      httpClient: httpClient,
    );
    if (source.providerType == ProviderType.localLlama) return inner;
    return LoggingChatClient(
      inner,
      log: log,
      title: '${source.providerType.name} · ${model.modelId}',
    );
  }
}

/// A [ChatClient] decorator that records each outgoing request into a
/// [PromptLog] before delegating.
///
/// This sits at the boundary every provider shares, so it captures cloud API
/// requests the same way regardless of provider. The captured [body] is a
/// readable transcript of the request payload, not the exact HTTP JSON.
class LoggingChatClient extends DelegatingChatClient {
  /// Wraps [inner], logging each request into [log] under [title].
  LoggingChatClient(super.inner, {required this.log, required this.title});

  /// The unified prompt log this client writes to.
  final PromptLog log;

  /// Short label identifying the model/provider for captured entries.
  final String title;

  void _capture(Iterable<ChatMessage> messages, ChatOptions? options) {
    log.add(
      PromptLogEntry(
        title: title,
        body: renderRequest(messages, options),
        capturedAt: DateTime.now(),
        tags: _tagsFor(messages, options),
      ),
    );
  }

  @override
  Future<ChatResponse> getResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) {
    _capture(messages, options);
    return super.getResponse(
      messages: messages,
      options: options,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) {
    _capture(messages, options);
    return super.getStreamingResponse(
      messages: messages,
      options: options,
      cancellationToken: cancellationToken,
    );
  }

  static List<String> _tagsFor(
    Iterable<ChatMessage> messages,
    ChatOptions? options,
  ) {
    final tools = options?.tools ?? const <AITool>[];
    return <String>[
      '${messages.length} messages',
      if (tools.isNotEmpty) '${tools.length} tools',
      if (options?.temperature != null) 'temp ${options!.temperature}',
      if (options?.maxOutputTokens != null)
        'maxTokens ${options!.maxOutputTokens}',
    ];
  }
}

/// Renders a chat request as a readable transcript.
///
/// Shows the system instructions, the names of declared tools, and each
/// message's role and content (text, plus markers for images, tool calls, and
/// tool results). This mirrors what the provider actually sends.
String renderRequest(Iterable<ChatMessage> messages, ChatOptions? options) {
  final buf = StringBuffer();

  final instructions = options?.instructions?.trim();
  if (instructions != null && instructions.isNotEmpty) {
    buf
      ..writeln('[system instructions]')
      ..writeln(instructions)
      ..writeln();
  }

  final tools = options?.tools ?? const <AITool>[];
  if (tools.isNotEmpty) {
    final names = tools
        .map((t) => t is AIFunctionDeclaration ? t.name : t.runtimeType.toString())
        .join(', ');
    buf
      ..writeln('[tools] $names')
      ..writeln();
  }

  for (final message in messages) {
    buf.writeln('[${message.role.value}]');
    final text = message.text.trim();
    if (text.isNotEmpty) buf.writeln(text);
    for (final content in message.contents) {
      if (content is DataContent && content.hasTopLevelMediaType('image')) {
        buf.writeln('(image)');
      } else if (content is FunctionCallContent) {
        buf.writeln(
          '(tool call ${content.name} ${jsonEncode(content.arguments ?? const <String, Object?>{})})',
        );
      } else if (content is FunctionResultContent) {
        buf.writeln('(tool result ${content.callId}: ${content.result})');
      }
    }
    buf.writeln();
  }

  return buf.toString().trimRight();
}

/// A [PromptInspector] that also mirrors each captured llama wire-format prompt
/// into the unified [PromptLog].
///
/// Registered in place of the plain inspector so local-model prompts appear in
/// the same log as cloud requests, while still exposing the latest snapshot for
/// any llama-specific UI.
class PromptLogInspector extends PromptInspector {
  /// Creates an inspector that mirrors snapshots into [log].
  PromptLogInspector(this.log, {this.title = 'local llama'});

  /// The unified prompt log this inspector mirrors into.
  final PromptLog log;

  /// Label used for captured local-model entries.
  final String title;

  @override
  void record(PromptSnapshot snapshot) {
    super.record(snapshot);
    log.add(
      PromptLogEntry(
        title: title,
        body: snapshot.text,
        capturedAt: snapshot.capturedAt,
        tags: <String>[
          '${snapshot.contextSize} ctx',
          'temp ${snapshot.temperature}',
          if (snapshot.topK != null) 'topK ${snapshot.topK}',
          if (snapshot.topP != null) 'topP ${snapshot.topP}',
          if (snapshot.seed != null) 'seed ${snapshot.seed}',
          'maxTokens ${snapshot.maxTokens}',
          if (snapshot.imageCount > 0) 'images ${snapshot.imageCount}',
          if (snapshot.stopSequences.isNotEmpty)
            'stop ${snapshot.stopSequences.join(' ')}',
        ],
      ),
    );
  }
}

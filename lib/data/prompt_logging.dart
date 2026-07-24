import 'dart:convert';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/chat.dart'
    show PromptInspector, PromptSnapshot;
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:http/http.dart' as http;

import 'agent_run_scope.dart';
import 'prompt_log.dart';
import 'tool_activity.dart';
import 'usage_store.dart';

/// Builds the local llama client for [source]/[model], with [scope]
/// identifying the conversation the client will serve (null for scope-less
/// internal callers such as hosting infrastructure).
typedef LocalChatClientResolver =
    ChatClient Function({
      required ModelSourceConfig source,
      required ModelConfig model,
      AgentScope? scope,
    });

/// A [ConfiguredChatClientFactory] that captures every prompt it produces.
///
/// Wraps each cloud provider's client in a [LoggingChatClient] so the request
/// (system instructions, declared tools, and message history) lands in [log].
/// Local llama clients already capture their exact wire-format prompt through
/// the shared [PromptInspector], so they are returned unwrapped to avoid
/// logging the same turn twice.
///
/// When a [usageSink] is supplied, every client — local llama included — is
/// additionally wrapped in a [UsageTrackingChatClient] so each model call's
/// token usage lands in the durable ledger and on the response messages.
/// Private conversations report to a [DiscardingUsageRecordSink] instead:
/// per-message usage still reaches the UI, but nothing is persisted.
class LoggingConfiguredChatClientFactory extends ConfiguredChatClientFactory {
  /// Creates a factory that records prompts into [log].
  LoggingConfiguredChatClientFactory({
    required this.log,
    this.usageSink,
    this.toolActivity,
    this.localClientResolver,
    super.isWeb,
    super.customClientResolver,
  });

  /// The unified prompt log every produced client writes to.
  final PromptLog log;

  /// Scope-aware resolver for local llama clients.
  ///
  /// The base factory's `customClientResolver` never sees the conversation
  /// scope, so local models are resolved here instead: the produced client
  /// derives its KV owner key from the scope, letting each conversation keep
  /// its own KV-cache lineage in the shared resident model. Falls back to
  /// the base resolver when null.
  final LocalChatClientResolver? localClientResolver;

  /// The ledger receiving one usage record per model call, when tracking is
  /// enabled.
  final UsageRecordSink? usageSink;

  /// Receives the running tools' names during a turn, when supplied, so the
  /// chat UI can show live tool activity.
  final ToolActivity? toolActivity;

  @override
  ChatClient createChatClient({
    required ModelSourceConfig source,
    required ModelConfig model,
    String? apiKey,
    http.Client? httpClient,
    AgentScope? scope,
  }) {
    // Local llama routes through the scope-aware resolver so the client can
    // key KV ownership to the conversation. The base factory would wrap its
    // provider client in TextFileInliningChatClient; replicate that here so
    // the local path keeps identical file-inlining behavior.
    final localResolver = localClientResolver;
    final inner =
        source.providerType == ProviderType.localLlama && localResolver != null
        ? TextFileInliningChatClient(
            localResolver(source: source, model: model, scope: scope),
          )
        : super.createChatClient(
            source: source,
            model: model,
            apiKey: apiKey,
            httpClient: httpClient,
            scope: scope,
          );
    final logged = source.providerType == ProviderType.localLlama
        ? inner
        : LoggingChatClient(
            inner,
            log: log,
            title: '${source.providerType.name} · ${model.modelId}',
          );
    final sink = usageSink;
    final tracked = sink == null
        ? logged
        : UsageTrackingChatClient(
            logged,
            sink: _sinkFor(sink, scope),
            modelId: model.modelId,
            sourceId: source.id,
            provider: source.providerType.name,
            scope: scope,
          );
    final activity = toolActivity;
    final conversationId = scope?.conversationId;
    // Scope-less clients (e.g. hosting internals or the title summarizer)
    // have no conversation channel to publish into, so they go untracked
    // rather than surfacing activity under an unrelated open chat.
    if (activity == null || conversationId == null) return tracked;
    return ToolActivityTrackingChatClient(
      tracked,
      registry: activity,
      conversationId: conversationId,
    );
  }

  /// Chooses the usage sink for [scope].
  ///
  /// Private conversations discard, exactly as before. Otherwise, when the
  /// caller supplied an [AgentRunScope] and the sink is the app's own
  /// [UsageStore], records are attributed to the scope's agent and to the
  /// run in flight. Any other combination falls through to the plain sink,
  /// so a test double or a scope-less internal caller still records usage —
  /// just without agent attribution.
  static UsageRecordSink _sinkFor(UsageRecordSink sink, AgentScope? scope) {
    if (scope?.isPrivate ?? false) return const DiscardingUsageRecordSink();
    if (scope is AgentRunScope && sink is UsageStore) {
      return sink.attributedTo(scope);
    }
    return sink;
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
        .map(
          (t) => t is AIFunctionDeclaration ? t.name : t.runtimeType.toString(),
        )
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

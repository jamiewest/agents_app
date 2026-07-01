import 'package:agents/agents.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter/foundation.dart';

import '../interface/attachments.dart';
import '../interface/chat_message.dart';
import '../interface/llm_provider.dart';
import '../token_smoother.dart';

/// Bridges an [AIAgent] into the chat UI's [LlmProvider] contract.
///
/// The provider keeps a lightweight UI transcript while sending agent-native
/// [ai.ChatMessage] values to the underlying agent.
class AgentLlmProvider extends LlmProvider with ChangeNotifier {
  /// Creates a provider backed by an [AIAgent].
  AgentLlmProvider({
    required this.agent,
    this.session,
    this.optionsBuilder,
    Iterable<ChatMessage>? history,
  }) : _history = List<ChatMessage>.from(history ?? const []);

  /// The core agent used to generate responses.
  final AIAgent agent;

  /// Optional session to use for stateful agent runs.
  final AgentSession? session;

  /// Optional factory for per-run options.
  final AgentRunOptions Function()? optionsBuilder;

  final List<ChatMessage> _history;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) {
    return _runAgent(prompt, attachments: attachments);
  }

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) {
    final userMessage = ChatMessage.user(prompt, attachments);
    final llmMessage = ChatMessage.llm();
    _history.addAll([userMessage, llmMessage]);
    if (!_disposed) notifyListeners();

    return _appendAgentResponse(prompt, attachments, llmMessage);
  }

  Stream<String> _appendAgentResponse(
    String prompt,
    Iterable<Attachment> attachments,
    ChatMessage llmMessage,
  ) async* {
    try {
      yield* _runAgent(prompt, attachments: attachments).smoothed().map((
        chunk,
      ) {
        llmMessage.append(chunk);
        return chunk;
      });
    } finally {
      // Notify after both success and streaming errors so listeners can
      // persist the transcript either way. The generator's finally can run
      // after disposal (e.g. navigating away mid-stream), so guard for that.
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Iterable<ChatMessage> get history => _history;

  @override
  set history(Iterable<ChatMessage> history) {
    _history
      ..clear()
      ..addAll(history);
    notifyListeners();
  }

  Stream<String> _runAgent(
    String prompt, {
    required Iterable<Attachment> attachments,
  }) async* {
    final message = _toAgentMessage(prompt, attachments);
    await for (final update in agent.runStreaming(
      session,
      optionsBuilder?.call(),
      messages: [message],
    )) {
      final text = update.text;
      if (text.isNotEmpty) {
        yield text;
      }
    }
  }

  ai.ChatMessage _toAgentMessage(
    String prompt,
    Iterable<Attachment> attachments,
  ) {
    return ai.ChatMessage(
      role: ai.ChatRole.user,
      contents: [
        ai.TextContent(prompt),
        for (final attachment in attachments) _toAgentContent(attachment),
      ],
    );
  }

  ai.AIContent _toAgentContent(Attachment attachment) {
    return switch (attachment) {
      FileAttachment(
        name: final name,
        mimeType: final mimeType,
        bytes: final bytes,
      ) =>
        ai.DataContent(bytes, mediaType: mimeType, name: name),
      LinkAttachment(url: final url, mimeType: final mimeType) => ai.UriContent(
        url,
        mediaType: mimeType,
      ),
    };
  }
}

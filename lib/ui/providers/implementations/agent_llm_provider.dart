import 'package:agents/agents.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter/foundation.dart';

import '../interface/attachments.dart';
import '../interface/chat_message.dart';
import '../interface/llm_provider.dart';
import '../interface/tool_approval.dart';
import '../token_smoother.dart';

/// Bridges an [AIAgent] into the chat UI's [LlmProvider] contract.
///
/// The provider keeps a lightweight UI transcript while sending agent-native
/// [ai.ChatMessage] values to the underlying agent.
///
/// When the agent's tool-approval middleware pauses a run on a
/// [ai.ToolApprovalRequestContent], the request surfaces through
/// [pendingToolApproval] and the run resumes via [sendToolApprovalStream].
class AgentLlmProvider extends LlmProvider
    with ChangeNotifier
    implements ToolApprovalSupport {
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

  ai.ToolApprovalRequestContent? _pendingApprovalContent;

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
    return _runMessage(_toAgentMessage(prompt, attachments));
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

    return _appendResponseTo(llmMessage, _toAgentMessage(prompt, attachments));
  }

  Stream<String> _appendResponseTo(
    ChatMessage llmMessage,
    ai.ChatMessage message,
  ) async* {
    try {
      yield* _runMessage(message).smoothed().map((chunk) {
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
  ToolApprovalRequest? get pendingToolApproval {
    final request = _pendingApprovalContent;
    if (request == null) return null;
    // The middleware types the call as [ai.ToolCallContent]; in practice a
    // function call carries the name and arguments, so match it dynamically
    // the same way the tool-approval middleware does.
    final dynamic toolCall = request.toolCall;
    return toolCall is ai.FunctionCallContent
        ? ToolApprovalRequest(
            toolName: toolCall.name,
            arguments: toolCall.arguments,
          )
        : ToolApprovalRequest(toolName: request.toolCall.callId);
  }

  @override
  Stream<String> sendToolApprovalStream(ToolApprovalDecision decision) {
    final request = _pendingApprovalContent;
    if (request == null) return const Stream.empty();
    _pendingApprovalContent = null;

    // Continue the response in the last assistant bubble when there is one,
    // so an approval pause does not split the reply and the transcript keeps
    // its user/llm pairing; only start a bubble in the degenerate case.
    var llmMessage = _history.isNotEmpty && _history.last.origin.isLlm
        ? _history.last
        : null;
    if (llmMessage == null) {
      llmMessage = ChatMessage.llm();
      _history.add(llmMessage);
    }
    if (!_disposed) notifyListeners();

    return _appendResponseTo(llmMessage, _toApprovalMessage(request, decision));
  }

  ai.ChatMessage _toApprovalMessage(
    ai.ToolApprovalRequestContent request,
    ToolApprovalDecision decision,
  ) {
    final approved = decision != ToolApprovalDecision.deny;
    final response = request.createResponse(
      approved,
      reason: approved ? null : 'Denied by the user.',
    );
    return ai.ChatMessage(
      role: ai.ChatRole.user,
      contents: [
        if (decision == ToolApprovalDecision.alwaysAllow)
          AlwaysApproveToolApprovalResponseContent(response, true, false)
        else
          response,
      ],
    );
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

  Stream<String> _runMessage(ai.ChatMessage message) async* {
    _pendingApprovalContent = null;
    await for (final update in agent.runStreaming(
      session,
      optionsBuilder?.call(),
      messages: [message],
    )) {
      // `update.text` only concatenates [ai.TextContent]; a thinking model
      // (e.g. Gemma 4 with reasoning enabled) opens its turn with a
      // [ai.TextReasoningContent] block that would otherwise stream as dead
      // air. Surface reasoning too so the user sees liveness. This UI's
      // [ChatMessage] has no separate reasoning channel yet, so reasoning and
      // answer currently share one bubble.
      final buffer = StringBuffer();
      for (final content in update.contents) {
        if (content is ai.TextReasoningContent) {
          buffer.write(content.text);
        } else if (content is ai.TextContent) {
          buffer.write(content.text);
        } else if (content is ai.ToolApprovalRequestContent) {
          // The tool-approval middleware ends the run after yielding the
          // request; hold it so the chat view can ask the user.
          _pendingApprovalContent = content;
        }
      }
      final text = buffer.toString();
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

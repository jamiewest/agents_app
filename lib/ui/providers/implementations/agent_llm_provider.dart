import 'dart:async';

import 'package:agents/agents.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter/foundation.dart';

import '../../../data/agent_run_store.dart';
import '../../../data/app_activity_monitor.dart';
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
    this.toolActivity,
    this.activity,
    this.runs,
    this.beginRun,
    Iterable<ChatMessage>? history,
  }) : _history = List<ChatMessage>.from(history ?? const []);

  /// The core agent used to generate responses.
  final AIAgent agent;

  /// Optional session to use for stateful agent runs.
  final AgentSession? session;

  /// Optional factory for per-run options.
  final AgentRunOptions Function()? optionsBuilder;

  /// Optional app-wide idle monitor; brackets each model turn so background
  /// work can tell when a generation is in flight.
  final AppActivityMonitor? activity;

  /// Live tool-activity label, when the app tracks it.
  ///
  /// Mirrored onto the streaming message while a turn is running so the chat
  /// view can show which tool the model is invoking.
  final ValueListenable<String?>? toolActivity;

  /// The run ledger, when telemetry is enabled for this conversation.
  ///
  /// Null for private conversations, which publish live status but persist
  /// nothing — the same rule the usage ledger already follows.
  final AgentRunTelemetryStore? runs;

  /// Opens a run record for a turn about to start.
  ///
  /// Supplied by the owner because only it knows the agent, model, and
  /// source labels to snapshot.
  final Future<AgentRunHandle> Function(AgentRunTelemetryStore runs)? beginRun;

  final List<ChatMessage> _history;

  bool _disposed = false;

  int _activeRuns = 0;

  AgentRunHandle? _currentRun;

  /// The id of the run in flight, or null between turns.
  ///
  /// Read lazily by [AgentRunScope.runIdResolver] so each model call — the
  /// tool loop and delegated agents included — is stamped with the turn it
  /// belongs to. One scope serves every turn of a conversation, so this
  /// cannot be captured when the scope is built.
  String? get currentRunId => _currentRun?.id;

  ai.ToolApprovalRequestContent? _pendingApprovalContent;

  /// Whether a turn is streaming or paused awaiting tool approval.
  ///
  /// Lets an owner defer disruptive work — such as swapping the backing
  /// [agent] after a settings change — until the current turn settles, so a
  /// live response is not torn off mid-stream.
  bool get isBusy => _activeRuns > 0 || _pendingApprovalContent != null;

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
    ai.ChatMessage message, {
    bool resuming = false,
  }) async* {
    final activity = toolActivity;
    // Per-bubble UI state: the message's own notification reaches the one
    // live bubble, so no provider-wide notify (which would also re-trigger
    // metadata persistence per tool call).
    void onToolActivity() => llmMessage.toolActivity = activity!.value;

    // Keep the original start across an approval pause so the status line's
    // timer spans the whole turn rather than restarting on resume. The plain
    // field is set before the notifying isGenerating write so one
    // notification publishes both.
    llmMessage
      ..turnStartedAt ??= DateTime.now()
      ..isGenerating = true;
    if (!_disposed) notifyListeners();

    // One run spans the whole turn, including an approval pause: the
    // middleware ends the agent run at the request and this method is
    // re-entered ([resuming]) to continue it, so the open run is kept
    // rather than a second one started. Same reasoning as
    // `turnStartedAt ??=` above.
    //
    // A *new* turn arriving while a run is open means the user typed a
    // message instead of answering the pending approval — the composer
    // stays live during a pause, and `_runMessage` drops the pending
    // request. That turn is abandoned, not failed, so its run is closed
    // before a fresh one opens; merging the two would produce one run
    // with both turns' model calls.
    final ledger = runs;
    final opener = beginRun;
    if (!resuming) {
      final abandoned = _currentRun;
      _currentRun = null;
      if (abandoned != null) unawaited(abandoned.succeed());
    }
    if (_currentRun == null && ledger != null && opener != null) {
      _currentRun = await opener(ledger);
    }

    activity?.addListener(onToolActivity);
    var failed = false;
    try {
      yield* _runMessage(
            message,
            // Each model call of the turn (tool-loop sub-calls included)
            // contributes one UsageContent; summing them makes the bubble's
            // badge cover the whole turn.
            onUsage: (details) {
              llmMessage.addUsage(details);
              _currentRun?.countModelCall();
            },
          )
          .smoothed()
          .map((chunk) {
            llmMessage.append(chunk);
            return chunk;
          })
          .handleError((Object error, StackTrace stackTrace) {
            // `yield*` forwards a source error straight to the output stream
            // rather than throwing it into this body, so a surrounding catch
            // would never see it. Flag the failure on the way past instead.
            failed = true;
            Error.throwWithStackTrace(error, stackTrace);
          });
    } finally {
      // A turn paused for tool approval is not over — leave its run open so
      // the resumed half is counted against the same record. A cancelled
      // stream completes normally and counts as a success: the user
      // stopping a reply is not an agent failure.
      final run = _currentRun;
      if (run != null && (failed || _pendingApprovalContent == null)) {
        _currentRun = null;
        unawaited(failed ? run.fail() : run.succeed());
      }
      activity?.removeListener(onToolActivity);
      final startedAt = llmMessage.turnStartedAt;
      llmMessage
        ..turnDuration = startedAt == null
            ? null
            : DateTime.now().difference(startedAt)
        ..toolActivity = null
        ..isGenerating = false;
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

    return _appendResponseTo(
      llmMessage,
      _toApprovalMessage(request, decision),
      resuming: true,
    );
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

  Stream<String> _runMessage(
    ai.ChatMessage message, {
    void Function(ai.UsageDetails details)? onUsage,
  }) async* {
    _pendingApprovalContent = null;
    _activeRuns++;
    activity?.beginInference();
    try {
      await for (final update in agent.runStreaming(
        session,
        optionsBuilder?.call(),
        messages: [message],
      )) {
        // `update.text` only concatenates [ai.TextContent]; a thinking model
        // (e.g. Gemma 4 with reasoning enabled) opens its turn with a
        // [ai.TextReasoningContent] block that would otherwise stream as dead
        // air. Surface reasoning too so the user sees liveness. This UI's
        // [ChatMessage] has no separate reasoning channel yet, so reasoning
        // and answer currently share one bubble.
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
          } else if (content is ai.UsageContent) {
            onUsage?.call(content.details);
          }
        }
        final text = buffer.toString();
        if (text.isNotEmpty) {
          yield text;
        }
      }
    } finally {
      _activeRuns--;
      activity?.endInference();
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

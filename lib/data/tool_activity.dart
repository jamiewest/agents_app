import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:flutter/foundation.dart';

/// The name(s) of the tools the current model turn is invoking, or null when
/// no tool is running.
///
/// [ToolActivityTrackingChatClient] drives the value from inside the chat
/// client pipeline; the chat UI mirrors it under the streaming bubble.
class ToolActivity extends ValueNotifier<String?> {
  /// Creates an idle tool-activity notifier.
  ToolActivity() : super(null);
}

/// A [ChatClient] decorator that reports tool activity to a [ToolActivity].
///
/// The function-invoking loop above this client swallows tool-call updates,
/// so the UI never sees them in the response stream. This decorator sits on
/// the raw model client, where every model call of the loop passes through:
/// a [FunctionCallContent] in the streamed response marks the tool as
/// running, and the tool executes between this stream's end and the next
/// model call, so the start of the next call clears the value again.
class ToolActivityTrackingChatClient extends DelegatingChatClient {
  /// Wraps [inner], reporting tool activity to [activity].
  ToolActivityTrackingChatClient(super.inner, {required this.activity});

  /// The notifier receiving the running tools' names.
  final ToolActivity activity;

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    // A new model call means any previously reported tool has finished.
    activity.value = null;
    final names = <String>[];
    await for (final update in super.getStreamingResponse(
      messages: messages,
      options: options,
      cancellationToken: cancellationToken,
    )) {
      for (final call in update.contents.whereType<FunctionCallContent>()) {
        if (call.name.isEmpty || names.contains(call.name)) continue;
        names.add(call.name);
        activity.value = names.join(', ');
      }
      yield update;
    }
  }
}

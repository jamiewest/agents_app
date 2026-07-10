import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:flutter/foundation.dart';

/// Registry of per-conversation tool-activity channels.
///
/// Each channel carries the name(s) of the tools a conversation's current
/// model turn is invoking, or null when no tool is running.
/// [ToolActivityTrackingChatClient] drives a channel from inside the chat
/// client pipeline; the chat UI mirrors it under that conversation's
/// streaming bubble. Keying by conversation keeps concurrent runs (a
/// background task next to the foreground chat) from bleeding status into
/// each other's bubbles.
class ToolActivity {
  final Map<String, ValueNotifier<String?>> _channels = {};
  final Map<String, int> _refCounts = {};

  /// Normalizes delegate/child scopes (`parent#delegate`) onto the parent
  /// conversation's channel, matching the old global-notifier behavior where
  /// a delegate's tool calls surfaced under the foreground chat's bubble.
  static String _rootOf(String conversationId) =>
      conversationId.split('#').first;

  /// Acquires the channel for [conversationId]; pair with [release].
  ValueListenable<String?> listen(String conversationId) {
    final key = _rootOf(conversationId);
    _refCounts[key] = (_refCounts[key] ?? 0) + 1;
    return _channels.putIfAbsent(key, () => ValueNotifier<String?>(null));
  }

  /// Releases one [listen] ref; the channel is disposed at zero.
  void release(String conversationId) {
    final key = _rootOf(conversationId);
    final count = (_refCounts[key] ?? 1) - 1;
    if (count > 0) {
      _refCounts[key] = count;
      return;
    }
    _refCounts.remove(key);
    _channels.remove(key)?.dispose();
  }

  /// Publishes [value] for [conversationId]'s turn.
  ///
  /// A no-op when no chat holds the channel, so background runs cost nothing
  /// and cannot surface in an unrelated bubble.
  void publish(String conversationId, String? value) {
    _channels[_rootOf(conversationId)]?.value = value;
  }
}

/// A [ChatClient] decorator that reports tool activity to a [ToolActivity]
/// channel.
///
/// The function-invoking loop above this client swallows tool-call updates,
/// so the UI never sees them in the response stream. This decorator sits on
/// the raw model client, where every model call of the loop passes through:
/// a [FunctionCallContent] in the streamed response marks the tool as
/// running, and the tool executes between this stream's end and the next
/// model call, so the start of the next call clears the value again.
class ToolActivityTrackingChatClient extends DelegatingChatClient {
  /// Wraps [inner], reporting tool activity to [registry] under
  /// [conversationId].
  ToolActivityTrackingChatClient(
    super.inner, {
    required this.registry,
    required this.conversationId,
  });

  /// The registry receiving the running tools' names.
  final ToolActivity registry;

  /// The conversation whose channel this client publishes into.
  final String conversationId;

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    // A new model call means any previously reported tool has finished.
    registry.publish(conversationId, null);
    final names = <String>[];
    await for (final update in super.getStreamingResponse(
      messages: messages,
      options: options,
      cancellationToken: cancellationToken,
    )) {
      for (final call in update.contents.whereType<FunctionCallContent>()) {
        if (call.name.isEmpty || names.contains(call.name)) continue;
        names.add(call.name);
        registry.publish(conversationId, names.join(', '));
      }
      yield update;
    }
  }
}

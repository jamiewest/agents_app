import 'package:agents_app/data/tool_activity.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolActivityTrackingChatClient', () {
    test('reports tool name on call content and clears on next call', () async {
      // Arrange: first model call emits a tool call, second streams the
      // answer — the shape a function-invoking loop produces.
      final registry = ToolActivity();
      final channel = registry.listen('conv-a');
      final client = ToolActivityTrackingChatClient(
        _ScriptedChatClient([
          [
            _update([TextContent('Let me check.')]),
            _update([
              FunctionCallContent(callId: 'c1', name: 'get_current_time'),
            ]),
          ],
          [
            _update([TextContent('It is 3pm.')]),
          ],
        ]),
        registry: registry,
        conversationId: 'conv-a',
      );
      final seen = <String?>[];
      channel.addListener(() => seen.add(channel.value));

      // Act: drain the first model call, then start the second.
      await client.getStreamingResponse(messages: _ask()).toList();
      final duringToolRun = channel.value;
      await client.getStreamingResponse(messages: _ask()).toList();

      // Assert: set while the tool runs, cleared when the next call starts.
      expect(duringToolRun, 'get_current_time');
      expect(channel.value, isNull);
      expect(seen, ['get_current_time', null]);
    });

    test('joins multiple distinct tool names, ignoring duplicates', () async {
      final registry = ToolActivity();
      final channel = registry.listen('conv-a');
      final client = ToolActivityTrackingChatClient(
        _ScriptedChatClient([
          [
            _update([
              FunctionCallContent(callId: 'c1', name: 'get_current_time'),
              FunctionCallContent(callId: 'c2', name: 'get_device_info'),
            ]),
            _update([
              FunctionCallContent(callId: 'c3', name: 'get_current_time'),
            ]),
          ],
        ]),
        registry: registry,
        conversationId: 'conv-a',
      );

      await client.getStreamingResponse(messages: _ask()).toList();

      expect(channel.value, 'get_current_time, get_device_info');
    });
  });

  group('ToolActivity registry', () {
    test('publishes only into the matching conversation channel', () async {
      final registry = ToolActivity();
      final channelA = registry.listen('conv-a');
      final channelB = registry.listen('conv-b');
      final client = ToolActivityTrackingChatClient(
        _ScriptedChatClient([
          [
            _update([FunctionCallContent(callId: 'c1', name: 'search')]),
          ],
        ]),
        registry: registry,
        conversationId: 'conv-b',
      );

      await client.getStreamingResponse(messages: _ask()).toList();

      // The background conversation's tool never bleeds into conv-a.
      expect(channelB.value, 'search');
      expect(channelA.value, isNull);
    });

    test('delegate scopes publish into the parent conversation', () async {
      final registry = ToolActivity();
      final channel = registry.listen('conv-a');
      final client = ToolActivityTrackingChatClient(
        _ScriptedChatClient([
          [
            _update([FunctionCallContent(callId: 'c1', name: 'search')]),
          ],
        ]),
        registry: registry,
        conversationId: 'conv-a#delegate',
      );

      await client.getStreamingResponse(messages: _ask()).toList();

      expect(channel.value, 'search');
    });

    test('publish with no listener is a no-op', () async {
      final registry = ToolActivity();
      final client = ToolActivityTrackingChatClient(
        _ScriptedChatClient([
          [
            _update([FunctionCallContent(callId: 'c1', name: 'search')]),
          ],
        ]),
        registry: registry,
        conversationId: 'background-task',
      );

      // No channel acquired for this conversation: nothing to observe,
      // nothing thrown.
      await client.getStreamingResponse(messages: _ask()).toList();
    });

    test('refcounted release keeps the channel until the last ref', () {
      final registry = ToolActivity();
      final first = registry.listen('conv-a');
      final second = registry.listen('conv-a');
      expect(identical(first, second), isTrue);

      registry.release('conv-a');
      // Still alive: the second ref holds it.
      registry.publish('conv-a', 'search');
      expect(first.value, 'search');

      registry.release('conv-a');
      // Disposed: publishing allocates nothing and reaches no one.
      registry.publish('conv-a', 'other');
      final fresh = registry.listen('conv-a');
      expect(fresh.value, isNull);
      expect(identical(fresh, first), isFalse);
    });
  });
}

ChatResponseUpdate _update(List<AIContent> contents) => ChatResponseUpdate(
  role: ChatRole.assistant,
  messageId: 'm1',
  contents: contents,
);

List<ChatMessage> _ask() => [
  ChatMessage(role: ChatRole.user, contents: [TextContent('what time?')]),
];

final class _ScriptedChatClient implements ChatClient {
  _ScriptedChatClient(this._scripts);

  final List<List<ChatResponseUpdate>> _scripts;
  int _call = 0;

  @override
  Future<ChatResponse> getResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Stream<ChatResponseUpdate> getStreamingResponse({
    required Iterable<ChatMessage> messages,
    ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => Stream.fromIterable(_scripts[_call++]);

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

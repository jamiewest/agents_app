import 'package:agents_app/data/tool_activity.dart';
import 'package:extensions/ai.dart';
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolActivityTrackingChatClient', () {
    test('reports tool name on call content and clears on next call', () async {
      // Arrange: first model call emits a tool call, second streams the
      // answer — the shape a function-invoking loop produces.
      final activity = ToolActivity();
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
        activity: activity,
      );
      final seen = <String?>[];
      activity.addListener(() => seen.add(activity.value));

      // Act: drain the first model call, then start the second.
      await client.getStreamingResponse(messages: _ask()).toList();
      final duringToolRun = activity.value;
      await client.getStreamingResponse(messages: _ask()).toList();

      // Assert: set while the tool runs, cleared when the next call starts.
      expect(duringToolRun, 'get_current_time');
      expect(activity.value, isNull);
      expect(seen, ['get_current_time', null]);
    });

    test('joins multiple distinct tool names, ignoring duplicates', () async {
      final activity = ToolActivity();
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
        activity: activity,
      );

      await client.getStreamingResponse(messages: _ask()).toList();

      expect(activity.value, 'get_current_time, get_device_info');
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

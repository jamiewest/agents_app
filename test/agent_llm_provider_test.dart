// ignore_for_file: non_constant_identifier_names

import 'dart:typed_data';

import 'package:agents/agents.dart';
import 'package:agents_app/ui/providers/providers.dart';
import 'package:agents_app/ui/providers/interface/chat_message.dart'
    as ui_messages;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentLlmProvider', () {
    test('sends the prompt as agent text content', () async {
      final agent = _FakeAgent(updates: [_textUpdate('hello back')]);
      final provider = AgentLlmProvider(agent: agent);

      await provider.sendMessageStream('hello').toList();

      expect(agent.capturedMessages, hasLength(1));
      final message = agent.capturedMessages.single;
      expect(message.role, ai.ChatRole.user);
      expect(message.contents, hasLength(1));
      expect(message.contents.single, isA<ai.TextContent>());
      expect(message.text, 'hello');
    });

    test('maps file and image attachments to data content', () async {
      final agent = _FakeAgent();
      final provider = AgentLlmProvider(agent: agent);
      final file = FileAttachment(
        name: 'notes.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final image = ImageFileAttachment(
        name: 'photo.png',
        mimeType: 'image/png',
        bytes: Uint8List.fromList([4, 5, 6]),
      );

      await provider
          .sendMessageStream('summarize', attachments: [file, image])
          .toList();

      final contents = agent.capturedMessages.single.contents;
      final dataContents = contents.whereType<ai.DataContent>().toList();
      expect(dataContents, hasLength(2));
      expect(dataContents[0].name, 'notes.txt');
      expect(dataContents[0].mediaType, 'text/plain');
      expect(dataContents[0].data, [1, 2, 3]);
      expect(dataContents[1].name, 'photo.png');
      expect(dataContents[1].mediaType, 'image/png');
      expect(dataContents[1].data, [4, 5, 6]);
    });

    test('maps link attachments to URI content', () async {
      final agent = _FakeAgent();
      final provider = AgentLlmProvider(agent: agent);
      final attachment = LinkAttachment(
        name: 'Dart',
        url: Uri.parse('https://dart.dev/'),
        mimeType: 'text/html',
      );

      await provider
          .sendMessageStream('read this', attachments: [attachment])
          .toList();

      final contents = agent.capturedMessages.single.contents;
      final uriContent = contents.whereType<ai.UriContent>().single;
      expect(uriContent.uri, Uri.parse('https://dart.dev/'));
      expect(uriContent.mediaType, 'text/html');
    });

    test('appends streamed chunks into one assistant UI message', () async {
      final agent = _FakeAgent(
        updates: [_textUpdate('hel'), _textUpdate('lo')],
      );
      final provider = AgentLlmProvider(agent: agent);

      final chunks = await provider.sendMessageStream('say hello').toList();

      expect(chunks, ['h', 'e', 'l', 'l', 'o']);
      expect(provider.history, hasLength(2));
      expect(provider.history.first.origin, MessageOrigin.user);
      expect(provider.history.last.origin, MessageOrigin.llm);
      expect(provider.history.last.text, 'hello');
    });

    test('adds the user message before the response stream is listened to', () {
      final agent = _FakeAgent(updates: [_textUpdate('ignored')]);
      final provider = AgentLlmProvider(agent: agent);
      var notificationCount = 0;
      provider.addListener(() => notificationCount++);

      final stream = provider.sendMessageStream('persist immediately');
      addTearDown(() async => stream.drain<void>());

      expect(provider.history, hasLength(2));
      expect(provider.history.first.origin, MessageOrigin.user);
      expect(provider.history.first.text, 'persist immediately');
      expect(provider.history.last.origin, MessageOrigin.llm);
      expect(provider.history.last.text, isNull);
      expect(notificationCount, 1);
      expect(agent.capturedMessages, isEmpty);
    });

    test(
      'keeps a user and assistant transcript pair when streaming fails',
      () async {
        final agent = _FakeAgent(error: StateError('boom'));
        final provider = AgentLlmProvider(agent: agent);

        await expectLater(
          provider.sendMessageStream('explode').toList(),
          throwsA(isA<StateError>()),
        );
        expect(provider.history, hasLength(2));
        expect(provider.history.first.origin, MessageOrigin.user);
        expect(provider.history.first.text, 'explode');
        expect(provider.history.last.origin, MessageOrigin.llm);
      },
    );

    test(
      'notifies listeners when a message is added and streaming finishes',
      () async {
        final agent = _FakeAgent(updates: [_textUpdate('done')]);
        final provider = AgentLlmProvider(agent: agent);
        var notificationCount = 0;
        provider.addListener(() => notificationCount++);

        await provider.sendMessageStream('go').toList();

        expect(notificationCount, 2);
      },
    );

    test(
      'notifies listeners when a message is added and streaming fails',
      () async {
        final agent = _FakeAgent(error: StateError('boom'));
        final provider = AgentLlmProvider(agent: agent);
        var notificationCount = 0;
        provider.addListener(() => notificationCount++);

        await expectLater(
          provider.sendMessageStream('go').toList(),
          throwsA(isA<StateError>()),
        );

        expect(notificationCount, 2);
      },
    );

    test('notifies listeners when history is replaced', () {
      final provider = AgentLlmProvider(agent: _FakeAgent());
      var notificationCount = 0;
      provider.addListener(() => notificationCount++);

      provider.history = [ui_messages.ChatMessage.user('hello', const [])];

      expect(notificationCount, 1);
      expect(provider.history.single.text, 'hello');
    });

    test('uses the provided session and run options', () async {
      final session = _FakeSession();
      final options = AgentRunOptions();
      final agent = _FakeAgent();
      final provider = AgentLlmProvider(
        agent: agent,
        session: session,
        optionsBuilder: () => options,
      );

      await provider.sendMessageStream('hello').toList();

      expect(agent.capturedSession, same(session));
      expect(agent.capturedOptions, same(options));
    });
  });
}

AgentResponseUpdate _textUpdate(String text) =>
    AgentResponseUpdate(role: ai.ChatRole.assistant, content: text);

class _FakeAgent extends AIAgent {
  _FakeAgent({List<AgentResponseUpdate>? updates, this.error})
    : updates = updates ?? const [];

  final List<AgentResponseUpdate> updates;
  final Object? error;
  List<ai.ChatMessage> capturedMessages = [];
  AgentSession? capturedSession;
  AgentRunOptions? capturedOptions;

  @override
  Future<AgentSession> createSessionCore({
    CancellationToken? cancellationToken,
  }) async => _FakeSession();

  @override
  Future<AgentSession> deserializeSessionCore(
    dynamic serializedState, {
    Object? JsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) async => _FakeSession();

  @override
  Future<AgentResponse> runCore(
    Iterable<ai.ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) async {
    throw UnimplementedError();
  }

  @override
  Stream<AgentResponseUpdate> runCoreStreaming(
    Iterable<ai.ChatMessage> messages, {
    AgentSession? session,
    AgentRunOptions? options,
    CancellationToken? cancellationToken,
  }) async* {
    capturedMessages = messages.toList();
    capturedSession = session;
    capturedOptions = options;
    final error = this.error;
    if (error != null) {
      throw error;
    }
    for (final update in updates) {
      yield update;
    }
  }

  @override
  Future<dynamic> serializeSessionCore(
    AgentSession session, {
    Object? JsonSerializerOptions,
    CancellationToken? cancellationToken,
  }) async => '{}';
}

class _FakeSession extends AgentSession {
  _FakeSession() : super(AgentSessionStateBag(null));
}

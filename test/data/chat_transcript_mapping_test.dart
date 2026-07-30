import 'dart:typed_data';

import 'package:agents_app/data/chat_transcript_mapping.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_flutter/chat_provider.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

TranscriptEntry _entry(
  ai.ChatMessage message, {
  int seq = 0,
  String sessionId = 's1',
}) => TranscriptEntry(seq: seq, sessionId: sessionId, message: message);

ai.ChatMessage _user(String text, {List<ai.AIContent> extra = const []}) =>
    ai.ChatMessage(
      role: ai.ChatRole.user,
      contents: [ai.TextContent(text), ...extra],
    );

ai.ChatMessage _assistant(String text, {List<ai.AIContent> extra = const []}) =>
    ai.ChatMessage(
      role: ai.ChatRole.assistant,
      contents: [ai.TextContent(text), ...extra],
    );

void main() {
  group('displayMessagesFrom', () {
    test('keeps user and assistant turns in order', () {
      final messages = displayMessagesFrom([
        _entry(_user('hello'), seq: 0),
        _entry(_assistant('hi there'), seq: 1),
      ]);

      expect(messages.map((m) => m.text), ['hello', 'hi there']);
      expect(messages.first.origin.isUser, isTrue);
      expect(messages.last.origin, MessageOrigin.llm);
    });

    test('skips text-empty turns, such as tool-call-only assistant turns', () {
      final messages = displayMessagesFrom([
        _entry(_user('do a thing')),
        _entry(_assistant('   ')),
        _entry(_assistant('done')),
      ]);

      expect(messages.map((m) => m.text), ['do a thing', 'done']);
    });

    test('hides system turns and loop/task plumbing authors', () {
      final messages = displayMessagesFrom([
        _entry(
          ai.ChatMessage(
            role: ai.ChatRole.system,
            contents: [ai.TextContent('you are a helpful agent')],
          ),
        ),
        _entry(_user('real question')),
        _entry(_user('wait for agents')..authorName = loopFeedbackAuthorName),
        _entry(_user('scheduled prompt')..authorName = taskPromptAuthorName),
      ]);

      expect(messages.map((m) => m.text), ['real question']);
    });

    test('sessionId narrows the transcript to that session', () {
      final messages = displayMessagesFrom([
        _entry(_user('first session'), sessionId: 's1'),
        _entry(_user('second session'), sessionId: 's2'),
      ], sessionId: 's2');

      expect(messages.map((m) => m.text), ['second session']);
    });

    test(
      'usage on a hidden turn rolls forward onto the next visible bubble',
      () {
        final usage = ai.UsageDetails()
          ..inputTokenCount = 10
          ..outputTokenCount = 5;
        final messages = displayMessagesFrom([
          _entry(_user('question')),
          // Tool-call-only turn: carries usage but no text, so it is not shown.
          _entry(_assistant('', extra: [ai.UsageContent(usage)])),
          _entry(_assistant('answer')),
        ]);

        expect(messages.map((m) => m.text), ['question', 'answer']);
        expect(messages.last.usage?.inputTokenCount, 10);
        expect(messages.last.usage?.outputTokenCount, 5);
      },
    );

    test('rebuilds file and link attachment chips on a user turn', () {
      final messages = displayMessagesFrom([
        _entry(
          _user(
            'see these',
            extra: [
              ai.DataContent(
                Uint8List.fromList([1, 2, 3]),
                mediaType: 'image/png',
                name: 'shot.png',
              ),
              ai.UriContent(
                Uri.parse('https://example.com/a/page.html'),
                mediaType: 'text/html',
              ),
            ],
          ),
        ),
      ]);

      final attachments = messages.single.attachments.toList();
      expect(attachments, hasLength(2));
      expect(attachments.first, isA<FileAttachment>());
      expect((attachments.first as FileAttachment).name, 'shot.png');
      expect(attachments.last, isA<LinkAttachment>());
      expect((attachments.last as LinkAttachment).name, 'page.html');
    });
  });

  group('transcriptMessagesFrom', () {
    test('drops empty-text placeholders and maps roles', () {
      final stored = transcriptMessagesFrom([
        ChatMessage.user('hello', const []),
        ChatMessage(
          origin: MessageOrigin.llm,
          text: '  ',
          attachments: const [],
        ),
        ChatMessage(
          origin: MessageOrigin.llm,
          text: 'hi',
          attachments: const [],
        ),
      ]);

      expect(stored.map((m) => m.text), ['hello', 'hi']);
      expect(stored.first.role, ai.ChatRole.user);
      expect(stored.last.role, ai.ChatRole.assistant);
    });

    test('round-trips a user attachment back into a display chip', () {
      final stored = transcriptMessagesFrom([
        ChatMessage.user('with a file', [
          FileAttachment.fileOrImage(
            name: 'notes.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList([65, 66]),
          ),
        ]),
      ]);

      final rebuilt = displayAttachmentsFor(stored.single);
      expect(rebuilt.single, isA<FileAttachment>());
      expect((rebuilt.single as FileAttachment).name, 'notes.txt');
    });
  });

  group('truncateConversationTitle', () {
    test('collapses whitespace and leaves short titles alone', () {
      expect(truncateConversationTitle('a\n  b\tc'), 'a b c');
    });

    test('clips long titles to 80 characters with an ellipsis', () {
      final title = truncateConversationTitle('x' * 200);
      expect(title.length, 80);
      expect(title.endsWith('…'), isTrue);
    });
  });
}

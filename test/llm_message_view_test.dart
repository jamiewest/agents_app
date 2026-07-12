// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:agents_app/ui/chat_view_model/chat_view_model.dart';
import 'package:agents_app/ui/chat_view_model/chat_view_model_provider.dart';
import 'package:agents_app/ui/providers/interface/attachments.dart';
import 'package:agents_app/ui/providers/interface/chat_message.dart';
import 'package:agents_app/ui/providers/interface/llm_provider.dart';
import 'package:agents_app/ui/providers/interface/message_origin.dart';
import 'package:agents_app/ui/views/attachment_view/image_attachment_view.dart';
import 'package:agents_app/ui/views/chat_message_view/llm_message_view.dart';
import 'package:agents_app/ui/views/jumping_dots_progress_indicator/jumping_dots_progress_indicator.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A valid 1x1 transparent PNG.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
  'hwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  ImageFileAttachment image(String name) =>
      ImageFileAttachment(name: name, mimeType: 'image/png', bytes: pngBytes);

  ChatMessage llmMessage({
    String? text,
    List<Attachment> attachments = const [],
  }) => ChatMessage(
    origin: MessageOrigin.llm,
    text: text,
    attachments: attachments,
  );

  testWidgets('renders a single assistant image', (tester) async {
    final message = llmMessage(attachments: [image('a.png')]);

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(ImageAttachmentView), findsOneWidget);
  });

  testWidgets('renders multiple assistant images in order', (tester) async {
    final message = llmMessage(
      attachments: [image('first.png'), image('second.png')],
    );

    await tester.pumpWidget(_host(LlmMessageView(message)));

    final views = tester
        .widgetList<ImageAttachmentView>(find.byType(ImageAttachmentView))
        .toList();
    expect(views, hasLength(2));
    expect(views[0].attachment.name, 'first.png');
    expect(views[1].attachment.name, 'second.png');
    expect(
      tester.getBottomLeft(find.byType(ImageAttachmentView).first).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byType(ImageAttachmentView).last).dy,
      ),
    );
  });

  testWidgets('renders image and markdown text together', (tester) async {
    final message = llmMessage(
      text: 'Here is the image.',
      attachments: [image('a.png')],
    );

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(ImageAttachmentView), findsOneWidget);
    expect(
      find.textContaining('Here is the image.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('an image-only message shows no jumping dots', (tester) async {
    final message = llmMessage(
      attachments: [
        LinkAttachment(
          name: 'generated image',
          url: Uri.parse('https://example.com/pic.png'),
          mimeType: 'image/png',
        ),
      ],
    );

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(ImageAttachmentView), findsOneWidget);
    expect(find.byType(JumpingDotsProgressIndicator), findsNothing);
  });

  testWidgets('a generating empty message shows jumping dots', (tester) async {
    final message = ChatMessage.llm()
      ..isGenerating = true
      ..turnStartedAt = DateTime.now();

    await tester.pumpWidget(_host(LlmMessageView(message)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(JumpingDotsProgressIndicator), findsOneWidget);

    // Unmount to stop the dots animation and the status line's timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a completed empty message shows neither dots nor text', (
    tester,
  ) async {
    final message = ChatMessage.llm();

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(JumpingDotsProgressIndicator), findsNothing);
    expect(find.byType(ImageAttachmentView), findsNothing);
  });

  testWidgets('live status renders below the image while generating', (
    tester,
  ) async {
    final message = llmMessage(attachments: [image('a.png')])
      ..isGenerating = true
      ..turnStartedAt = DateTime.now();

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(LiveTurnStatus), findsOneWidget);
    expect(find.byType(JumpingDotsProgressIndicator), findsNothing);
    expect(
      tester.getTopLeft(find.byType(LiveTurnStatus)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(ImageAttachmentView)).dy,
      ),
    );

    // Unmount to cancel the status line's ticking timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('usage badge renders below image and text after completion', (
    tester,
  ) async {
    final message = llmMessage(
      text: 'The answer.',
      attachments: [image('a.png')],
    )..usage = ai.UsageDetails(inputTokenCount: 1234, outputTokenCount: 56);

    await tester.pumpWidget(_host(LlmMessageView(message)));

    expect(find.byType(UsageBadge), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(UsageBadge)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byType(ImageAttachmentView)).dy,
      ),
    );
  });

  testWidgets('custom responseBuilder still renders alongside an image', (
    tester,
  ) async {
    final message = llmMessage(
      text: 'The answer.',
      attachments: [image('a.png')],
    );

    await tester.pumpWidget(
      _host(
        LlmMessageView(message),
        responseBuilder: (context, response) => Text('custom:$response'),
      ),
    );

    expect(find.byType(ImageAttachmentView), findsOneWidget);
    expect(find.text('custom:The answer.'), findsOneWidget);
  });
}

Widget _host(
  Widget child, {
  Widget Function(BuildContext, String)? responseBuilder,
}) => MaterialApp(
  home: Scaffold(
    // The real chat renders messages inside a scrollable history list, so
    // taller-than-viewport content (e.g. stacked images) must not overflow.
    body: SingleChildScrollView(
      child: ChatViewModelProvider(
        viewModel: ChatViewModel(
          provider: _FakeLlmProvider(),
          style: null,
          suggestions: const [],
          welcomeMessage: null,
          responseBuilder: responseBuilder,
          messageSender: null,
          onMessageSubmitted: null,
          speechToText: null,
          enableAttachments: false,
          enableVoiceNotes: false,
        ),
        child: child,
      ),
    ),
  ),
);

final class _FakeLlmProvider extends LlmProvider with ChangeNotifier {
  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) => const Stream.empty();

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) => const Stream.empty();

  @override
  Iterable<ChatMessage> get history => const [];

  @override
  set history(Iterable<ChatMessage> history) {}
}

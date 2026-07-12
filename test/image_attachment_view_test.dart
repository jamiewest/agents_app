// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agents_app/ui/dialogs/image_preview_dialog.dart';
import 'package:agents_app/ui/providers/interface/attachments.dart';
import 'package:agents_app/ui/views/attachment_view/attachment_view.dart';
import 'package:agents_app/ui/views/attachment_view/image_attachment_view.dart';
import 'package:agents_app/ui/views/attachment_view/link_attachment_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A valid 1x1 transparent PNG.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
  'hwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  tearDown(() {
    imageCache
      ..clear()
      ..clearLiveImages();
  });

  ImageFileAttachment imageFile({String name = 'generated.png'}) =>
      ImageFileAttachment(name: name, mimeType: 'image/png', bytes: pngBytes);

  LinkAttachment imageLink({String url = 'https://example.com/pic.png'}) =>
      LinkAttachment(
        name: 'generated image',
        url: Uri.parse(url),
        mimeType: 'image/png',
      );

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('Attachment.isImage', () {
    test('classifies attachments', () {
      expect(imageFile().isImage, isTrue);
      expect(imageLink().isImage, isTrue);
      expect(
        FileAttachment(
          name: 'notes.txt',
          mimeType: 'text/plain',
          bytes: pngBytes,
        ).isImage,
        isFalse,
      );
      expect(
        LinkAttachment(
          name: 'docs',
          url: Uri.parse('https://example.com/page.html'),
        ).isImage,
        isFalse,
      );
    });
  });

  group('ImageAttachmentView', () {
    testWidgets('renders in-memory bytes with Image.memory', (tester) async {
      await tester.pumpWidget(host(ImageAttachmentView(imageFile())));
      await _settleImages(tester);

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());
    });

    testWidgets('renders an image URL with Image.network', (tester) async {
      await _pumpWithNetworkClient(
        tester,
        host(ImageAttachmentView(imageLink())),
        statusCode: 200,
        body: pngBytes,
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<NetworkImage>());
    });

    testWidgets('does not overflow under narrow constraints', (tester) async {
      await tester.pumpWidget(
        host(SizedBox(width: 80, child: ImageAttachmentView(imageFile()))),
      );
      await _settleImages(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the error placeholder for invalid bytes', (
      tester,
    ) async {
      final broken = ImageFileAttachment(
        name: 'broken.png',
        mimeType: 'image/png',
        bytes: utf8.encode('not a png'),
      );
      await tester.pumpWidget(host(ImageAttachmentView(broken)));
      await _settleImages(tester);

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('broken.png'), findsOneWidget);
    });

    testWidgets('renders the error placeholder for a failed request', (
      tester,
    ) async {
      await _pumpWithNetworkClient(
        tester,
        host(
          ImageAttachmentView(
            imageLink(url: 'https://example.com/missing.png'),
          ),
        ),
        statusCode: 404,
        body: const [],
      );

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('generated image'), findsOneWidget);
    });

    testWidgets('tapping the image opens the preview dialog', (tester) async {
      await tester.pumpWidget(host(ImageAttachmentView(imageFile())));
      await _settleImages(tester);

      await tester.tap(find.byType(ImageAttachmentView));
      await tester.pumpAndSettle();

      expect(find.byType(ImagePreviewDialog), findsOneWidget);
    });

    testWidgets('exposes a semantics label with the attachment name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(ImageAttachmentView(imageFile())));
      await _settleImages(tester);

      expect(find.bySemanticsLabel('Open image generated.png'), findsOneWidget);
      handle.dispose();
    });
  });

  group('AttachmentView routing', () {
    testWidgets('routes an image URL to ImageAttachmentView', (tester) async {
      await _pumpWithNetworkClient(
        tester,
        host(AttachmentView(imageLink())),
        statusCode: 200,
        body: pngBytes,
      );

      expect(find.byType(ImageAttachmentView), findsOneWidget);
      expect(find.byType(LinkAttachmentView), findsNothing);
    });

    testWidgets('routes a non-image URL to LinkAttachmentView', (tester) async {
      final link = LinkAttachment(
        name: 'Flutter docs',
        url: Uri.parse('https://example.com/page.html'),
      );
      await _pumpWithNetworkClient(
        tester,
        host(AttachmentView(link)),
        statusCode: 404,
        body: const [],
      );

      expect(find.byType(LinkAttachmentView), findsOneWidget);
      expect(find.byType(ImageAttachmentView), findsNothing);
    });
  });
}

/// Lets pending image decodes and fetches complete, then rebuilds.
Future<void> _settleImages(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

/// Pumps [widget] while network images resolve against a canned HTTP
/// response, resetting the debug client before the binding's end-of-test
/// invariant check.
Future<void> _pumpWithNetworkClient(
  WidgetTester tester,
  Widget widget, {
  required int statusCode,
  required List<int> body,
}) async {
  debugNetworkImageHttpClientProvider = () => _FakeHttpClient(statusCode, body);
  try {
    await tester.pumpWidget(widget);
    await _settleImages(tester);
  } finally {
    debugNetworkImageHttpClientProvider = null;
  }
}

/// An [HttpClient] that answers every request with a canned response, so
/// tests never touch the real network. Installed per test through
/// [debugNetworkImageHttpClientProvider] because [NetworkImage] caches its
/// real client statically on first use.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.statusCode, this.body);

  final int statusCode;
  final List<int> body;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpClientRequest(statusCode, body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.statusCode, this.body);

  final int statusCode;
  final List<int> body;

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpClientResponse(statusCode, body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.body);

  @override
  final int statusCode;

  final List<int> body;

  @override
  int get contentLength => body.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([body]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

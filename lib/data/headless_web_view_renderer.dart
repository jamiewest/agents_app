// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'search_url_web_search_source.dart';

/// A [WebPageRenderer] backed by a hidden platform WebView.
///
/// The page loads in a WebView that is never attached to the widget tree,
/// so its JavaScript runs exactly as in a real browser; the live DOM is
/// then serialized back to HTML. Snapshots are polled rather than taken on
/// the load event because script-built pages keep mutating the document
/// afterwards — Google even navigates to a second URL before showing
/// results — and a mid-navigation poll simply fails and is retried.
///
/// Renders run one at a time: concurrent [render] calls queue, so
/// simultaneous searches cannot stack up WebViews. Supported wherever
/// `webview_flutter` has an implementation (Android, iOS, macOS).
class HeadlessWebViewRenderer implements WebPageRenderer {
  /// Creates a renderer that polls every [pollInterval] and gives a page
  /// up to [timeout] to produce an accepted snapshot.
  HeadlessWebViewRenderer({
    this.timeout = const Duration(seconds: 12),
    this.pollInterval = const Duration(milliseconds: 400),
  });

  /// The time budget per page before the last snapshot is returned as-is.
  final Duration timeout;

  /// How long to wait between document snapshots.
  final Duration pollInterval;

  Future<void> _previousRender = Future.value();

  @override
  Future<RenderedWebPage> render(
    Uri url, {
    String? userAgent,
    bool Function(RenderedWebPage page)? isReady,
  }) {
    final render = _previousRender.then(
      (_) => _render(url, userAgent: userAgent, isReady: isReady),
    );
    _previousRender = render.then((_) {}, onError: (_) {});
    return render;
  }

  Future<RenderedWebPage> _render(
    Uri url, {
    required String? userAgent,
    required bool Function(RenderedWebPage page)? isReady,
  }) async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    if (userAgent != null) await controller.setUserAgent(userAgent);
    await controller.loadRequest(url);
    final deadline = DateTime.now().add(timeout);
    RenderedWebPage page = (html: '', url: url);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      final snapshot = await _snapshot(controller, url);
      if (snapshot == null) continue;
      page = snapshot;
      if (isReady?.call(snapshot) ?? snapshot.html.isNotEmpty) break;
    }
    // Parks the WebView on a blank page so timers and media stop; the
    // platform side is released when the controller is collected.
    await controller.loadRequest(Uri.parse('about:blank'));
    return page;
  }

  /// The current document and address, or `null` when the page is
  /// mid-navigation and cannot be queried yet.
  Future<RenderedWebPage?> _snapshot(
    WebViewController controller,
    Uri requested,
  ) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      final current = Uri.tryParse(await controller.currentUrl() ?? '');
      return (
        html: _scriptResultText(raw),
        url: (current?.hasScheme ?? false) ? current! : requested,
      );
    } on Exception {
      return null;
    }
  }

  /// Normalizes a script result to plain text: some platform WebViews
  /// (Android) hand strings back JSON-encoded, others (WebKit) raw.
  static String _scriptResultText(Object value) {
    final text = value.toString();
    if (text.startsWith('"') && text.endsWith('"')) {
      try {
        return jsonDecode(text) as String;
      } on FormatException {
        return text;
      }
    }
    return text;
  }
}

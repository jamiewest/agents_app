// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/system.dart';
import 'package:http/http.dart' as http;

/// A page snapshot from a [WebPageRenderer]: the document HTML and the URL
/// it was served from, which redirects can move off the requested one.
typedef RenderedWebPage = ({String html, Uri url});

/// Renders a web page in a browser engine and returns its HTML after the
/// page's own JavaScript has run.
///
/// Script-built pages keep mutating the document after the load event —
/// some, like google.com, even navigate again before showing results — so
/// implementations take successive snapshots and complete with the first
/// one [isReady] accepts, or the last one taken when their time budget
/// runs out. A `null` [isReady] accepts the first non-empty document.
abstract interface class WebPageRenderer {
  /// Loads [url], sending [userAgent] when given, and returns the
  /// document once [isReady] accepts a snapshot or time runs out.
  Future<RenderedWebPage> render(
    Uri url, {
    String? userAgent,
    bool Function(RenderedWebPage page)? isReady,
  });
}

/// A [WebSearchSource] that queries any search endpoint the user provides.
///
/// The request is the configured URL with the search terms appended as the
/// `q` query parameter, followed verbatim by [urlSuffix] —
/// `https://searx.example.com/search` with suffix `&format=json` becomes
/// `https://searx.example.com/search?q=my+search+terms&format=json` — so any
/// engine that takes `q` works: a self-hosted SearXNG instance, DuckDuckGo's
/// HTML endpoint, or anything else. Query parameters already present in the
/// configured URL (an instance key, a language pin) are preserved.
///
/// A JSON response (SearXNG's `format=json` shape: a top-level `results`
/// list of `url`/`title`/`content` objects) is parsed structurally,
/// including snippets. Anything else is treated as HTML, and results are the
/// links parsed from it with generic heuristics standing in for
/// provider-specific parsing:
///
/// - Redirect wrappers are unwrapped: a link whose query carries an absolute
///   `http(s)` URL (DuckDuckGo's `uddg`, Google's `/url?q=`) yields that
///   destination instead of the tracking hop.
/// - Links back to the search host itself — navigation, pagination,
///   preferences — are dropped, as are links with no text.
/// - Snippets are left empty — the model reads promising results with
///   `open_web_page`.
///
/// Server-rendered engines work as-is; an engine that only builds its
/// result list in JavaScript needs a [renderer], which runs the page in a
/// browser engine before the same parsing applies.
class SearchUrlWebSearchSource implements WebSearchSource {
  /// Creates a source that searches through [searchUrl].
  ///
  /// [httpClient] is injectable for tests; when omitted each call uses the
  /// default top-level client.
  SearchUrlWebSearchSource({
    required this.searchUrl,
    this.urlSuffix = '',
    this.userAgent,
    this.renderer,
    this._httpClient,
  });

  /// The user-configured search endpoint, without the `q` parameter.
  final Uri searchUrl;

  /// User-configured URL text appended verbatim after the `q` parameter.
  ///
  /// A leading `&` is implied when missing, so `format=json` and
  /// `&format=json` configure the same request.
  final String urlSuffix;

  /// The `User-Agent` header sent with each request, or `null` to send the
  /// HTTP client's default.
  final String? userAgent;

  /// Renders the results page in a browser engine before parsing, for
  /// engines that build their results with JavaScript; `null` fetches the
  /// page over plain HTTP.
  final WebPageRenderer? renderer;

  final http.Client? _httpClient;

  static final RegExp _anchorPattern = RegExp(
    r'''<a\s[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>''',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  Future<Iterable<WebSearchResult>> search(
    String query, {
    required int maxResults,
    CancellationToken? cancellationToken,
  }) async {
    final url = _requestUrl(query);
    cancellationToken?.throwIfCancellationRequested();
    if (renderer case final renderer?) {
      // Ready once a snapshot parses to a few results: interstitials like
      // Google's enable-JavaScript page leave at most a stray support link,
      // while a genuinely short result list still arrives through the last
      // snapshot when the renderer's budget runs out.
      final page = await renderer.render(
        url,
        userAgent: userAgent,
        isReady: (page) =>
            _parseHtmlResults(page.html, page.url, maxResults).length >=
            min(3, maxResults),
      );
      cancellationToken?.throwIfCancellationRequested();
      return _parseHtmlResults(page.html, page.url, maxResults);
    }
    final headers = userAgent == null ? null : {'User-Agent': userAgent!};
    final response = _httpClient == null
        ? await http.get(url, headers: headers)
        : await _httpClient.get(url, headers: headers);
    cancellationToken?.throwIfCancellationRequested();
    if (response.statusCode != 200) {
      throw http.ClientException(
        'The search endpoint returned HTTP ${response.statusCode}.',
        url,
      );
    }

    final body = response.body;
    if (body.trimLeft().startsWith('{')) {
      return _parseJsonResults(body, maxResults);
    }
    return _parseHtmlResults(body, response.request?.url ?? url, maxResults);
  }

  /// The configured URL with `q` and then [urlSuffix] appended.
  ///
  /// Built textually rather than through [Uri.replace] so the stored URL and
  /// the suffix reach the engine exactly as the user wrote them.
  Uri _requestUrl(String query) {
    final base = searchUrl.toString();
    final separator = !base.contains('?')
        ? '?'
        : base.endsWith('?') || base.endsWith('&')
        ? ''
        : '&';
    var suffix = urlSuffix.trim();
    if (suffix.isNotEmpty &&
        !suffix.startsWith('&') &&
        !suffix.startsWith('#')) {
      suffix = '&$suffix';
    }
    return Uri.parse(
      '$base${separator}q=${Uri.encodeQueryComponent(query)}$suffix',
    );
  }

  /// Parses a SearXNG-style JSON body: a top-level `results` list of
  /// `url`/`title`/`content` objects. Other JSON shapes yield no results.
  static Iterable<WebSearchResult> _parseJsonResults(
    String body,
    int maxResults,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const <WebSearchResult>[];
    }
    final entries = decoded is Map ? decoded['results'] : null;
    if (entries is! List) return const <WebSearchResult>[];
    final results = <WebSearchResult>[];
    for (final entry in entries) {
      if (results.length >= maxResults) break;
      if (entry is! Map) continue;
      final url = (entry['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      results.add(
        WebSearchResult(
          title: (entry['title'] ?? '').toString(),
          url: url,
          snippet: (entry['content'] ?? '').toString(),
        ),
      );
    }
    return results;
  }

  /// Parses result links out of an HTML body.
  static Iterable<WebSearchResult> _parseHtmlResults(
    String body,
    Uri base,
    int maxResults,
  ) {
    final seen = <String>{};
    final results = <WebSearchResult>[];
    for (final match in _anchorPattern.allMatches(body)) {
      if (results.length >= maxResults) break;
      final resolved = _resolveResultUrl(base, match.group(1) ?? '');
      if (resolved == null || resolved.host == base.host) continue;
      final title = _plainText(match.group(2) ?? '');
      if (title.isEmpty || !seen.add(resolved.toString())) continue;
      results.add(WebSearchResult(title: title, url: resolved.toString()));
    }
    return results;
  }

  /// Resolves [href] against [base] and unwraps redirect links, returning
  /// `null` for anything that is not a plain `http(s)` destination.
  static Uri? _resolveResultUrl(Uri base, String href) {
    final trimmed = href.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    Uri resolved;
    try {
      resolved = base.resolve(trimmed);
    } on FormatException {
      return null;
    }
    // A result link whose query carries an absolute web URL is a redirect
    // wrapper; the embedded destination is the real result.
    for (final value in resolved.queryParameters.values) {
      final embedded = Uri.tryParse(value);
      if (embedded != null &&
          (embedded.scheme == 'http' || embedded.scheme == 'https') &&
          embedded.hasAuthority) {
        resolved = embedded;
        break;
      }
    }
    final isWebUrl =
        (resolved.scheme == 'http' || resolved.scheme == 'https') &&
        resolved.hasAuthority;
    return isWebUrl ? resolved : null;
  }
}

/// Reduces anchor inner HTML to plain text.
///
/// Result titles arrive with highlight tags, entity-encoded characters, and
/// layout whitespace; the model wants none of them.
String _plainText(String value) => value
    .replaceAll(RegExp('<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/search_url_web_search_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A renderer that replays canned snapshots, completing with the first one
/// the caller accepts — like the real one's poll loop, minus the WebView.
class _FakeRenderer implements WebPageRenderer {
  _FakeRenderer(this.snapshots);

  final List<RenderedWebPage> snapshots;
  Uri? seenUrl;
  String? seenUserAgent;
  int taken = 0;

  @override
  Future<RenderedWebPage> render(
    Uri url, {
    String? userAgent,
    bool Function(RenderedWebPage page)? isReady,
  }) async {
    seenUrl = url;
    seenUserAgent = userAgent;
    for (final page in snapshots) {
      taken++;
      if (isReady?.call(page) ?? page.html.isNotEmpty) return page;
    }
    return snapshots.last;
  }
}

void main() {
  test('appends the query as q and keeps existing parameters', () async {
    late http.Request seen;
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search?language=en'),
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('<html></html>', 200);
      }),
    );

    await source.search('flutter web search', maxResults: 3);

    expect(seen.url.host, 'searx.example.com');
    expect(seen.url.path, '/search');
    expect(seen.url.queryParameters['language'], 'en');
    expect(seen.url.queryParameters['q'], 'flutter web search');
  });

  test('sends the configured user agent, or none by default', () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response('{"results": []}', 200);
    });

    await SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      userAgent: 'Mozilla/5.0 (Test)',
      httpClient: client,
    ).search('flutter', maxResults: 3);
    expect(seen.headers['User-Agent'], 'Mozilla/5.0 (Test)');

    await SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      httpClient: client,
    ).search('flutter', maxResults: 3);
    expect(seen.headers.containsKey('User-Agent'), isFalse);
  });

  test('appends the suffix verbatim after the query', () async {
    late http.Request seen;
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      urlSuffix: '&format=json&language=en',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('{"results": []}', 200);
      }),
    );

    await source.search('flutter', maxResults: 3);

    expect(
      seen.url.toString(),
      'https://searx.example.com/search?q=flutter&format=json&language=en',
    );
  });

  test('implies the leading & when the suffix omits it', () async {
    late http.Request seen;
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      urlSuffix: 'format=json',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response('{"results": []}', 200);
      }),
    );

    await source.search('flutter', maxResults: 3);

    expect(seen.url.queryParameters['format'], 'json');
  });

  test('parses SearXNG-style JSON results with snippets', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      urlSuffix: '&format=json',
      httpClient: MockClient(
        (request) async => http.Response('''
          {"query": "flutter", "results": [
            {"url": "https://flutter.dev/", "title": "Flutter",
             "content": "Build apps for any screen."},
            {"url": "", "title": "No url"},
            {"url": "https://dart.dev/", "title": "Dart"}
          ]}
          ''', 200),
      ),
    );

    final results = (await source.search('flutter', maxResults: 2)).toList();

    expect(results, hasLength(2));
    expect(results[0].title, 'Flutter');
    expect(results[0].url, 'https://flutter.dev/');
    expect(results[0].snippet, 'Build apps for any screen.');
    expect(results[1].title, 'Dart');
  });

  test('parses external links, cleans titles, and skips nav links', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      httpClient: MockClient(
        (request) async => http.Response('''
          <html><body>
            <a href="/preferences">Preferences</a>
            <a href="https://searx.example.com/search?q=x&pageno=2">Next</a>
            <a href="https://flutter.dev/">Dart &amp;
              <strong>Flutter</strong></a>
            <a href="https://flutter.dev/">Dart &amp; Flutter (duplicate)</a>
            <a href="https://dart.dev/overview"><img src="icon.png"/></a>
            <a href="https://docs.flutter.dev/">Docs</a>
          </body></html>
          ''', 200),
      ),
    );

    final results = (await source.search('flutter', maxResults: 5)).toList();

    expect(results, hasLength(2));
    expect(results[0].title, 'Dart & Flutter');
    expect(results[0].url, 'https://flutter.dev/');
    expect(results[1].title, 'Docs');
    expect(results[1].url, 'https://docs.flutter.dev/');
  });

  test('unwraps redirect links and resolves relative ones', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://html.duckduckgo.com/html/'),
      httpClient: MockClient(
        (request) async => http.Response('''
          <html><body>
            <a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fflutter.dev%2F">
              Flutter</a>
          </body></html>
          ''', 200),
      ),
    );

    final results = (await source.search('flutter', maxResults: 5)).toList();

    expect(results, hasLength(1));
    expect(results[0].title, 'Flutter');
    expect(results[0].url, 'https://flutter.dev/');
  });

  test('caps the result count at maxResults', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      httpClient: MockClient(
        (request) async => http.Response(
          [
            for (var i = 0; i < 10; i++)
              '<a href="https://example$i.dev/">Result $i</a>',
          ].join(),
          200,
        ),
      ),
    );

    expect(await source.search('anything', maxResults: 4), hasLength(4));
  });

  test('returns no results for a page without links', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      httpClient: MockClient(
        (request) async => http.Response('<html><body>Nope</body></html>', 200),
      ),
    );

    expect(await source.search('anything', maxResults: 5), isEmpty);
  });

  test('a renderer feeds rendered HTML through the same parsing', () async {
    final renderer = _FakeRenderer([
      (
        html: '''
          <html><body>
            <a href="https://flutter.dev/">Flutter</a>
            <a href="https://dart.dev/">Dart</a>
            <a href="https://docs.flutter.dev/">Docs</a>
          </body></html>
          ''',
        url: Uri.parse('https://www.google.com/search?q=flutter'),
      ),
    ]);
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://google.com/search'),
      userAgent: 'Mozilla/5.0 (Test)',
      renderer: renderer,
    );

    final results = (await source.search('flutter', maxResults: 5)).toList();

    expect(results, hasLength(3));
    expect(results[0].url, 'https://flutter.dev/');
    expect(renderer.seenUrl?.queryParameters['q'], 'flutter');
    expect(renderer.seenUserAgent, 'Mozilla/5.0 (Test)');
  });

  test('rejects interstitial snapshots until results render', () async {
    const interstitial =
        '<html><body>'
        '<a href="https://support.google.com/websearch">feedback</a>'
        '</body></html>';
    const results =
        '<html><body>'
        '<a href="https://flutter.dev/">Flutter</a>'
        '<a href="https://dart.dev/">Dart</a>'
        '<a href="https://docs.flutter.dev/">Docs</a>'
        '</body></html>';
    final base = Uri.parse('https://www.google.com/search?q=flutter');
    final renderer = _FakeRenderer([
      (html: interstitial, url: base),
      (html: results, url: base),
    ]);
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://google.com/search'),
      renderer: renderer,
    );

    final found = (await source.search('flutter', maxResults: 5)).toList();

    expect(renderer.taken, 2);
    expect(
      found.map((result) => result.url),
      isNot(contains(contains('support.google.com'))),
    );
    expect(found, hasLength(3));
  });

  test(
    'filters rendered links against the page URL, not the request',
    () async {
      final renderer = _FakeRenderer([
        (
          html: '''
          <html><body>
            <a href="https://www.google.com/preferences">Settings</a>
            <a href="https://flutter.dev/">Flutter</a>
          </body></html>
          ''',
          url: Uri.parse('https://www.google.com/search?q=flutter'),
        ),
      ]);
      final source = SearchUrlWebSearchSource(
        searchUrl: Uri.parse('https://google.com/search'),
        renderer: renderer,
      );

      final results = (await source.search('flutter', maxResults: 1)).toList();

      expect(results.single.url, 'https://flutter.dev/');
    },
  );

  test('throws on a non-200 response', () async {
    final source = SearchUrlWebSearchSource(
      searchUrl: Uri.parse('https://searx.example.com/search'),
      httpClient: MockClient(
        (request) async => http.Response('rate limited', 429),
      ),
    );

    await expectLater(
      source.search('anything', maxResults: 5),
      throwsA(
        isA<http.ClientException>().having(
          (error) => error.message,
          'message',
          contains('429'),
        ),
      ),
    );
  });
}

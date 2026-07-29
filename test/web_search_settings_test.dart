// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/search_url_web_search_source.dart';
import 'package:agents_app/data/web_search_settings.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// A renderer stand-in; the settings only hand it to sources, never call it.
class _FakeRenderer implements WebPageRenderer {
  @override
  Future<RenderedWebPage> render(
    Uri url, {
    String? userAgent,
    bool Function(RenderedWebPage page)? isReady,
  }) async => (html: '', url: url);
}

/// A secret store whose reads always fail, like a sandboxed build without
/// keychain entitlements.
class _ThrowingSecretStore extends SecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('no keychain');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keychain');

  @override
  Future<void> delete(String key) async => throw StateError('no keychain');
}

const _newClient = SearchClientConfig(
  id: '',
  name: '',
  searchUrl: 'searx.example.com/search?q=test&language=en',
);

void main() {
  test('starts unconfigured and loads as unconfigured when empty', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    expect(settings.isConfigured, isFalse);
    await settings.load();
    expect(settings.isConfigured, isFalse);
    expect(settings.source, isNull);
    expect(settings.clients, isEmpty);
    expect(settings.profiles, isEmpty);
  });

  test('saveClient assigns an id, normalizes, and selects the first', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final stored = await settings.saveClient(_newClient);

    expect(stored.id, isNotEmpty);
    expect(stored.name, 'searx.example.com');
    expect(stored.searchUrl, 'https://searx.example.com/search?language=en');
    expect(settings.selectedClientId, stored.id);
    expect(settings.isConfigured, isTrue);
  });

  test('saveClient updates in place and keeps the selection', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final first = await settings.saveClient(_newClient);
    final second = await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Backup',
        searchUrl: 'https://backup.example.com/search',
      ),
    );

    final edited = await settings.saveClient(
      SearchClientConfig(
        id: second.id,
        name: 'Backup edited',
        searchUrl: second.searchUrl,
        urlSuffix: '&format=json',
      ),
    );

    expect(settings.clients, hasLength(2));
    expect(edited.id, second.id);
    expect(settings.clients.last.name, 'Backup edited');
    expect(settings.clients.last.urlSuffix, '&format=json');
    expect(settings.selectedClientId, first.id);
  });

  test('selectClient switches the source to that client', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    await settings.saveClient(_newClient);
    final second = await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Backup',
        searchUrl: 'https://backup.example.com/search',
      ),
    );

    await settings.selectClient(second.id);

    final source = settings.source! as SearchUrlWebSearchSource;
    expect(source.searchUrl.host, 'backup.example.com');
  });

  test('deleteClient moves the selection to the first remaining', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final first = await settings.saveClient(_newClient);
    final second = await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Backup',
        searchUrl: 'https://backup.example.com/search',
      ),
    );

    await settings.deleteClient(first.id);
    expect(settings.selectedClientId, second.id);

    await settings.deleteClient(second.id);
    expect(settings.selectedClientId, isNull);
    expect(settings.isConfigured, isFalse);
  });

  test('the source sends the associated profile user agent', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final profile = await settings.saveProfile(
      const UserAgentProfile(id: '', name: 'Safari', userAgent: 'Mozilla/5.0'),
    );
    await settings.saveClient(
      SearchClientConfig(
        id: '',
        name: 'Searx',
        searchUrl: 'https://searx.example.com/search',
        userAgentProfileId: profile.id,
      ),
    );

    final source = settings.source! as SearchUrlWebSearchSource;
    expect(source.userAgent, 'Mozilla/5.0');
  });

  test('an unassociated client uses the default user agent', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    await settings.saveClient(_newClient);

    expect((settings.source! as SearchUrlWebSearchSource).userAgent, isNull);
  });

  test('the source renders JavaScript only for opted-in clients', () async {
    final renderer = _FakeRenderer();
    final secrets = InMemorySecretStore();
    final settings = WebSearchSettings(secrets, renderer: renderer);
    final client = await settings.saveClient(_newClient);
    expect((settings.source! as SearchUrlWebSearchSource).renderer, isNull);

    await settings.saveClient(
      SearchClientConfig(
        id: client.id,
        name: client.name,
        searchUrl: client.searchUrl,
        renderJavaScript: true,
      ),
    );
    expect(
      (settings.source! as SearchUrlWebSearchSource).renderer,
      same(renderer),
    );

    final reloaded = WebSearchSettings(secrets, renderer: renderer);
    await reloaded.load();
    expect(reloaded.clients.single.renderJavaScript, isTrue);
    expect(
      (reloaded.source! as SearchUrlWebSearchSource).renderer,
      same(renderer),
    );
  });

  test(
    'a renderJavaScript client without a renderer uses plain HTTP',
    () async {
      final settings = WebSearchSettings(InMemorySecretStore());
      await settings.saveClient(
        const SearchClientConfig(
          id: '',
          name: 'Google',
          searchUrl: 'https://google.com/search',
          renderJavaScript: true,
        ),
      );

      expect((settings.source! as SearchUrlWebSearchSource).renderer, isNull);
    },
  );

  test('saveProfile assigns an id and rejects a blank value', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final stored = await settings.saveProfile(
      const UserAgentProfile(id: '', name: '', userAgent: ' Mozilla/5.0 '),
    );

    expect(stored.id, isNotEmpty);
    expect(stored.userAgent, 'Mozilla/5.0');
    expect(stored.name, 'Mozilla/5.0');
    await expectLater(
      settings.saveProfile(
        const UserAgentProfile(id: '', name: 'Blank', userAgent: '  '),
      ),
      throwsArgumentError,
    );
  });

  test('deleteProfile detaches it from clients', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    final profile = await settings.saveProfile(
      const UserAgentProfile(id: '', name: 'Safari', userAgent: 'Mozilla/5.0'),
    );
    await settings.saveClient(
      SearchClientConfig(
        id: '',
        name: 'Searx',
        searchUrl: 'https://searx.example.com/search',
        userAgentProfileId: profile.id,
        renderJavaScript: true,
      ),
    );

    await settings.deleteProfile(profile.id);

    expect(settings.profiles, isEmpty);
    expect(settings.clients.single.userAgentProfileId, isNull);
    expect(settings.clients.single.renderJavaScript, isTrue);
    expect((settings.source! as SearchUrlWebSearchSource).userAgent, isNull);
  });

  test(
    'a reloaded instance restores clients, profiles, and selection',
    () async {
      final secrets = InMemorySecretStore();
      final settings = WebSearchSettings(secrets);
      final profile = await settings.saveProfile(
        const UserAgentProfile(
          id: '',
          name: 'Safari',
          userAgent: 'Mozilla/5.0',
        ),
      );
      await settings.saveClient(_newClient);
      final second = await settings.saveClient(
        SearchClientConfig(
          id: '',
          name: 'Backup',
          searchUrl: 'https://backup.example.com/search',
          urlSuffix: '&format=json',
          userAgentProfileId: profile.id,
        ),
      );
      await settings.selectClient(second.id);

      final reloaded = WebSearchSettings(secrets);
      await reloaded.load();

      expect(reloaded.clients, hasLength(2));
      expect(reloaded.profiles, hasLength(1));
      expect(reloaded.selectedClientId, second.id);
      final source = reloaded.source! as SearchUrlWebSearchSource;
      expect(source.searchUrl.host, 'backup.example.com');
      expect(source.urlSuffix, '&format=json');
      expect(source.userAgent, 'Mozilla/5.0');
    },
  );

  test('load migrates the legacy single-client keys once', () async {
    final secrets = InMemorySecretStore();
    await secrets.write(
      WebSearchSettings.legacySearchUrlSecretKey,
      'https://searx.example.com/search',
    );
    await secrets.write(
      WebSearchSettings.legacyUrlSuffixSecretKey,
      '&format=json',
    );

    final settings = WebSearchSettings(secrets);
    await settings.load();

    final client = settings.clients.single;
    expect(client.name, 'searx.example.com');
    expect(client.searchUrl, 'https://searx.example.com/search');
    expect(client.urlSuffix, '&format=json');
    expect(settings.selectedClientId, client.id);
    expect(
      await secrets.read(WebSearchSettings.legacySearchUrlSecretKey),
      isNull,
    );
    expect(
      await secrets.read(WebSearchSettings.legacyUrlSuffixSecretKey),
      isNull,
    );
    expect(await secrets.read(WebSearchSettings.configSecretKey), isNotNull);
  });

  test('saveClient rejects an invalid URL', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    await expectLater(
      settings.saveClient(
        const SearchClientConfig(id: '', name: '', searchUrl: '   '),
      ),
      throwsArgumentError,
    );
    expect(settings.isConfigured, isFalse);
  });

  test('load survives a failing secret store', () async {
    final settings = WebSearchSettings(_ThrowingSecretStore());
    await settings.load();
    expect(settings.source, isNull);
  });

  test('notifies listeners on every mutation', () async {
    final settings = WebSearchSettings(InMemorySecretStore());
    var notifications = 0;
    settings.addListener(() => notifications++);

    final client = await settings.saveClient(_newClient);
    final second = await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Backup',
        searchUrl: 'https://backup.example.com/search',
      ),
    );
    await settings.selectClient(second.id);
    final profile = await settings.saveProfile(
      const UserAgentProfile(id: '', name: 'Safari', userAgent: 'Mozilla/5.0'),
    );
    await settings.deleteProfile(profile.id);
    await settings.deleteClient(client.id);
    await settings.load();
    expect(notifications, 7);
  });
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';

import 'search_url_web_search_source.dart';

String _newId(String prefix) {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}

/// A reusable, user-managed `User-Agent` header value.
///
/// Search clients reference profiles by [id], so editing one profile updates
/// every client that uses it.
class UserAgentProfile {
  /// Creates a user-agent profile.
  const UserAgentProfile({
    required this.id,
    required this.name,
    required this.userAgent,
  });

  /// Restores a profile from its stored JSON.
  factory UserAgentProfile.fromJson(Map<String, Object?> json) =>
      UserAgentProfile(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        userAgent: (json['userAgent'] ?? '').toString(),
      );

  /// The stable identifier clients reference. Empty on a not-yet-saved
  /// profile; [WebSearchSettings.saveProfile] assigns one.
  final String id;

  /// The display name shown in lists and pickers.
  final String name;

  /// The `User-Agent` header value sent with search requests.
  final String userAgent;

  /// Converts this profile to storable JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'userAgent': userAgent,
  };
}

/// One saved search endpoint: a URL, an optional after-query suffix, and an
/// optional user-agent profile association.
class SearchClientConfig {
  /// Creates a search client configuration.
  const SearchClientConfig({
    required this.id,
    required this.name,
    required this.searchUrl,
    this.urlSuffix = '',
    this.userAgentProfileId,
    this.renderJavaScript = false,
  });

  /// Restores a client from its stored JSON.
  factory SearchClientConfig.fromJson(Map<String, Object?> json) {
    final profileId = (json['userAgentProfileId'] ?? '').toString();
    return SearchClientConfig(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      searchUrl: (json['searchUrl'] ?? '').toString(),
      urlSuffix: (json['urlSuffix'] ?? '').toString(),
      userAgentProfileId: profileId.isEmpty ? null : profileId,
      renderJavaScript: json['renderJavaScript'] == true,
    );
  }

  /// The stable identifier. Empty on a not-yet-saved client;
  /// [WebSearchSettings.saveClient] assigns one.
  final String id;

  /// The display name shown in lists.
  final String name;

  /// The search endpoint the query is appended to.
  final String searchUrl;

  /// URL text appended verbatim after the `q` parameter.
  final String urlSuffix;

  /// The associated [UserAgentProfile.id], or `null` to send the default
  /// user agent.
  final String? userAgentProfileId;

  /// Whether searches load the results page in a hidden browser engine so
  /// its JavaScript runs before parsing, for engines like google.com that
  /// serve script-built result pages.
  final bool renderJavaScript;

  /// Converts this client to storable JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'searchUrl': searchUrl,
    'urlSuffix': urlSuffix,
    if (userAgentProfileId != null) 'userAgentProfileId': userAgentProfileId,
    'renderJavaScript': renderJavaScript,
  };
}

/// The persisted web-search configuration: saved search clients, reusable
/// user-agent profiles, and which client the `web_search` tool uses.
///
/// While a client is selected, agents get the local `web_search` and
/// `open_web_page` tools in place of the model provider's hosted search
/// marker; each agent's own web-search access toggle still gates them. The
/// whole configuration lives as one JSON document in the [SecretStore]
/// beside the model API keys — a self-hosted instance address or
/// key-carrying parameter can itself be sensitive — and never reaches the
/// model-visible tool surface.
///
/// A [ChangeNotifier] so Settings reflects edits immediately. Agents pick up
/// a configuration change the next time one is built for a conversation.
class WebSearchSettings extends ChangeNotifier {
  /// Creates a [WebSearchSettings] over [secrets].
  ///
  /// [renderer] serves clients whose [SearchClientConfig.renderJavaScript]
  /// is on; leave it `null` on platforms without a WebView implementation,
  /// where those clients fall back to plain HTTP.
  WebSearchSettings(this._secrets, {this._renderer});

  /// The secret key holding the JSON configuration document.
  static const String configSecretKey = 'agents_app.web_search.config';

  /// The pre-multi-client secret key holding the single search URL.
  ///
  /// Read once by [load] to migrate into [configSecretKey], and wiped on
  /// app reset in case migration never ran.
  static const String legacySearchUrlSecretKey =
      'agents_app.web_search.search_url';

  /// The pre-multi-client secret key holding the after-query suffix.
  static const String legacyUrlSuffixSecretKey =
      'agents_app.web_search.url_suffix';

  final SecretStore _secrets;
  final WebPageRenderer? _renderer;
  List<SearchClientConfig> _clients = const [];
  List<UserAgentProfile> _profiles = const [];
  String? _selectedClientId;

  /// The saved search clients, in creation order.
  List<SearchClientConfig> get clients => List.unmodifiable(_clients);

  /// The saved user-agent profiles, in creation order.
  List<UserAgentProfile> get profiles => List.unmodifiable(_profiles);

  /// The id of the client the tool uses, or `null` while none is saved.
  String? get selectedClientId => _selectedClientId;

  /// The client the tool uses, or `null` while none is saved.
  SearchClientConfig? get selectedClient =>
      _clientById(_selectedClientId ?? '');

  /// Whether a search client is selected for the tool to use.
  bool get isConfigured => source != null;

  /// The search source for the selected client, or `null` while
  /// unconfigured.
  ///
  /// Built fresh per read so it always reflects the current client, suffix,
  /// and user-agent association.
  WebSearchSource? get source {
    final client = selectedClient;
    if (client == null) return null;
    final url = normalizeWebUrl(client.searchUrl);
    if (url == null) return null;
    return SearchUrlWebSearchSource(
      searchUrl: url,
      urlSuffix: client.urlSuffix,
      userAgent: profileFor(client)?.userAgent,
      renderer: client.renderJavaScript ? _renderer : null,
    );
  }

  /// The profile associated with [client], or `null` for the default user
  /// agent (including a dangling reference).
  UserAgentProfile? profileFor(SearchClientConfig client) {
    for (final profile in _profiles) {
      if (profile.id == client.userAgentProfileId) return profile;
    }
    return null;
  }

  /// Loads the stored configuration, migrating the legacy single-client
  /// keys when no document exists yet.
  ///
  /// Runs during app bootstrap, so a platform keychain rejection (e.g. a
  /// sandboxed debug build without keychain entitlements) leaves web search
  /// unconfigured instead of aborting startup.
  Future<void> load() async {
    try {
      final stored = (await _secrets.read(configSecretKey))?.trim() ?? '';
      if (stored.isEmpty) {
        await _migrateLegacyKeys();
      } else {
        _restore(stored);
      }
    } catch (error, stackTrace) {
      developer.log(
        'Failed to read the web search configuration.',
        name: 'agents_app.web_search_settings',
        error: error,
        stackTrace: stackTrace,
      );
      _clients = const [];
      _profiles = const [];
      _selectedClientId = null;
    }
    notifyListeners();
  }

  /// Adds or updates [client] and returns the stored value.
  ///
  /// A blank [SearchClientConfig.id] means "new" and gets one assigned; a
  /// blank name falls back to the URL's host. The URL is normalized (a
  /// missing scheme defaults to HTTPS, a pasted `q` parameter is dropped);
  /// throws [ArgumentError] when it is not a web URL. The first saved
  /// client is selected automatically.
  Future<SearchClientConfig> saveClient(SearchClientConfig client) async {
    final normalized = normalizeWebUrl(client.searchUrl);
    if (normalized == null) {
      throw ArgumentError('A valid http(s) search URL is required.');
    }
    final url = _withoutQueryParameterQ(normalized);
    final name = client.name.trim();
    final stored = SearchClientConfig(
      id: client.id.isEmpty ? _newId('search-client') : client.id,
      name: name.isEmpty ? url.host : name,
      searchUrl: url.toString(),
      urlSuffix: client.urlSuffix.trim(),
      userAgentProfileId: client.userAgentProfileId,
      renderJavaScript: client.renderJavaScript,
    );
    final index = _clients.indexWhere((c) => c.id == stored.id);
    _clients = [
      for (final existing in _clients)
        if (existing.id == stored.id) stored else existing,
      if (index < 0) stored,
    ];
    _selectedClientId ??= stored.id;
    await _persist();
    return stored;
  }

  /// Deletes the client with [id].
  ///
  /// When it was selected, selection moves to the first remaining client —
  /// or to none, restoring the provider's hosted search where available.
  Future<void> deleteClient(String id) async {
    _clients = [
      for (final client in _clients)
        if (client.id != id) client,
    ];
    if (_selectedClientId == id) {
      _selectedClientId = _clients.isEmpty ? null : _clients.first.id;
    }
    await _persist();
  }

  /// Makes the client with [id] the one the tool uses.
  Future<void> selectClient(String id) async {
    if (_clientById(id) == null || _selectedClientId == id) return;
    _selectedClientId = id;
    await _persist();
  }

  /// Adds or updates [profile] and returns the stored value.
  ///
  /// A blank [UserAgentProfile.id] means "new" and gets one assigned.
  /// Throws [ArgumentError] when the user-agent value is blank; a blank
  /// name falls back to the value itself.
  Future<UserAgentProfile> saveProfile(UserAgentProfile profile) async {
    final userAgent = profile.userAgent.trim();
    if (userAgent.isEmpty) {
      throw ArgumentError('A user-agent value is required.');
    }
    final name = profile.name.trim();
    final stored = UserAgentProfile(
      id: profile.id.isEmpty ? _newId('user-agent') : profile.id,
      name: name.isEmpty ? userAgent : name,
      userAgent: userAgent,
    );
    final index = _profiles.indexWhere((p) => p.id == stored.id);
    _profiles = [
      for (final existing in _profiles)
        if (existing.id == stored.id) stored else existing,
      if (index < 0) stored,
    ];
    await _persist();
    return stored;
  }

  /// Deletes the profile with [id], detaching it from any client that
  /// references it; those clients fall back to the default user agent.
  Future<void> deleteProfile(String id) async {
    _profiles = [
      for (final profile in _profiles)
        if (profile.id != id) profile,
    ];
    _clients = [
      for (final client in _clients)
        if (client.userAgentProfileId == id)
          SearchClientConfig(
            id: client.id,
            name: client.name,
            searchUrl: client.searchUrl,
            urlSuffix: client.urlSuffix,
            renderJavaScript: client.renderJavaScript,
          )
        else
          client,
    ];
    await _persist();
  }

  SearchClientConfig? _clientById(String id) {
    for (final client in _clients) {
      if (client.id == id) return client;
    }
    return null;
  }

  void _restore(String stored) {
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return;
    _clients = [
      if (decoded['clients'] case final List entries)
        for (final entry in entries)
          if (entry is Map)
            SearchClientConfig.fromJson(entry.cast<String, Object?>()),
    ];
    _profiles = [
      if (decoded['profiles'] case final List entries)
        for (final entry in entries)
          if (entry is Map)
            UserAgentProfile.fromJson(entry.cast<String, Object?>()),
    ];
    final selected = (decoded['selectedClientId'] ?? '').toString();
    _selectedClientId = _clientById(selected)?.id ?? _clients.firstOrNull?.id;
  }

  /// Converts the pre-multi-client keys into a single saved client, then
  /// deletes them so this runs at most once.
  Future<void> _migrateLegacyKeys() async {
    final storedUrl =
        (await _secrets.read(legacySearchUrlSecretKey))?.trim() ?? '';
    final url = normalizeWebUrl(storedUrl);
    if (url == null) return;
    final suffix =
        (await _secrets.read(legacyUrlSuffixSecretKey))?.trim() ?? '';
    final client = SearchClientConfig(
      id: _newId('search-client'),
      name: url.host,
      searchUrl: url.toString(),
      urlSuffix: suffix,
    );
    _clients = [client];
    _selectedClientId = client.id;
    await _persist(notify: false);
    await _secrets.delete(legacySearchUrlSecretKey);
    await _secrets.delete(legacyUrlSuffixSecretKey);
  }

  Future<void> _persist({bool notify = true}) async {
    await _secrets.write(
      configSecretKey,
      jsonEncode({
        'clients': [for (final client in _clients) client.toJson()],
        'profiles': [for (final profile in _profiles) profile.toJson()],
        if (_selectedClientId != null) 'selectedClientId': _selectedClientId,
      }),
    );
    if (notify) notifyListeners();
  }

  /// Drops any `q` parameter from [url], keeping the rest of its query.
  ///
  /// Users paste example searches like `…/search?q=test`; the stored
  /// endpoint must not carry a second, stale query.
  static Uri _withoutQueryParameterQ(Uri url) {
    if (!url.queryParametersAll.containsKey('q')) return url;
    final parameters = {...url.queryParametersAll}..remove('q');
    if (parameters.isEmpty) {
      return Uri.parse(url.toString().split('?').first);
    }
    return url.replace(queryParameters: parameters);
  }
}

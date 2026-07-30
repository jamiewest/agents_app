// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/web_search_settings_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

(ServiceProvider, WebSearchSettings) _webSearchServices() {
  final settings = WebSearchSettings(InMemorySecretStore());
  final services = ServiceCollection()
    ..addSingleton<WebSearchSettings>((_) => settings);
  return (services.buildServiceProvider(), settings);
}

Future<void> _pump(WidgetTester tester, ServiceProvider services) => tester
    .pumpWidget(MaterialApp(home: WebSearchSettingsScreen(services: services)));

void main() {
  testWidgets('shows empty hints before anything is saved', (tester) async {
    final (services, _) = _webSearchServices();
    await _pump(tester, services);

    expect(find.text('No search clients yet.'), findsOneWidget);
    expect(find.text('No user agent profiles yet.'), findsOneWidget);
  });

  testWidgets('adds a search client through the dialog', (tester) async {
    final (services, settings) = _webSearchServices();
    await _pump(tester, services);

    await tester.tap(find.text('Add search client'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search URL'),
      'https://searx.example.com/search',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.clients, hasLength(1));
    expect(settings.isConfigured, isTrue);
    expect(find.text('searx.example.com'), findsOneWidget);
    expect(find.text('No search clients yet.'), findsNothing);
  });

  testWidgets('rejects an invalid search URL inline', (tester) async {
    final (services, settings) = _webSearchServices();
    await _pump(tester, services);

    await tester.tap(find.text('Add search client'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.clients, isEmpty);
    expect(find.textContaining('Enter a valid web address'), findsOneWidget);
  });

  testWidgets('associates a profile with a client', (tester) async {
    final (services, settings) = _webSearchServices();
    final profile = await settings.saveProfile(
      const UserAgentProfile(
        id: '',
        name: 'Desktop Safari',
        userAgent: 'Mozilla/5.0 (Test)',
      ),
    );
    await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Searx',
        searchUrl: 'https://searx.example.com/search',
      ),
    );
    await _pump(tester, services);
    expect(find.textContaining('User agent: default'), findsOneWidget);

    await tester.tap(find.text('Searx'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desktop Safari').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.clients.single.userAgentProfileId, profile.id);
    expect(find.textContaining('User agent: Desktop Safari'), findsOneWidget);
  });

  testWidgets('deleting a profile detaches it after confirmation', (
    tester,
  ) async {
    final (services, settings) = _webSearchServices();
    final profile = await settings.saveProfile(
      const UserAgentProfile(
        id: '',
        name: 'Desktop Safari',
        userAgent: 'Mozilla/5.0 (Test)',
      ),
    );
    await settings.saveClient(
      SearchClientConfig(
        id: '',
        name: 'Searx',
        searchUrl: 'https://searx.example.com/search',
        userAgentProfileId: profile.id,
      ),
    );
    await _pump(tester, services);
    expect(find.textContaining('User agent: Desktop Safari'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(settings.profiles, isEmpty);
    expect(settings.clients.single.userAgentProfileId, isNull);
    expect(find.textContaining('User agent: default'), findsOneWidget);
  });

  testWidgets('toggles JavaScript rendering through the dialog', (
    tester,
  ) async {
    final (services, settings) = _webSearchServices();
    await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Google',
        searchUrl: 'https://google.com/search',
      ),
    );
    await _pump(tester, services);
    expect(find.textContaining('renders JavaScript'), findsNothing);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Render JavaScript'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.clients.single.renderJavaScript, isTrue);
    expect(find.textContaining('renders JavaScript'), findsOneWidget);
  });

  testWidgets('checking a client selects it', (tester) async {
    final (services, settings) = _webSearchServices();
    await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'First',
        searchUrl: 'https://first.example.com/search',
      ),
    );
    final second = await settings.saveClient(
      const SearchClientConfig(
        id: '',
        name: 'Second',
        searchUrl: 'https://second.example.com/search',
      ),
    );
    await _pump(tester, services);

    await tester.tap(find.byTooltip('Use this search client'));
    await tester.pumpAndSettle();

    expect(settings.selectedClientId, second.id);
  });
}

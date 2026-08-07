// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/app/app_bootstrap.dart';
import 'package:agents_app/app/app_router.dart';
import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/features/tor/secure_onion_identity_store.dart';
import 'package:agents_app/features/tor/tor_settings.dart';
import 'package:agents_app/ui/screens/settings_home_screen.dart';
import 'package:agents_app/ui/screens/tor_settings_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tor_flutter/tor_flutter.dart';
import 'package:tor_flutter/tor_flutter_testing.dart';

/// Resolves locations against the real router without building the app.
///
/// Deliberately not a widget test. Pumping the whole app drags in
/// [AppBootstrap], which needs `debugLocalModelStoreRoot` — a process-global
/// six test files already fight over, and a seventh made the suite hang.
/// Whether a location matches a route needs no widgets at all.
GoRouter _router(ServiceProvider services) => createAppRouter(
  services: services,
  bootstrap: AppBootstrap(services),
  scheduler: TaskSchedulerService(services),
);

ServiceProvider _buildServices({bool withTor = true}) {
  final kv = InMemoryKeyValueStore();
  final services = ServiceCollection()
    ..addSingleton<ThemeSettings>((_) => ThemeSettings(kv))
    ..addSingleton<UserProfileSettings>((_) => UserProfileSettings(kv))
    ..addSingleton<PushoverSettings>(
      (sp) => PushoverSettings(sp.getRequiredService<SecretStore>()),
    )
    ..addSingleton<EmbeddingSettings>(
      (sp) => EmbeddingSettings(
        keyValueStore: kv,
        manager: sp.getRequiredService<ConfiguredAgentsManager>(),
      ),
    )
    ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
    ..addSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    )
    ..addSingleton<AgentRunTelemetryStore>(
      (sp) => AgentRunTelemetryStore(sp.getRequiredService<RecordStore>()),
    )
    ..addConfiguredAgents(
      keyValueStore: (_) => kv,
      secretStore: (_) => InMemorySecretStore(),
      chatClientFactory: (_) => ConfiguredChatClientFactory(
        customClientResolver:
            ({required source, required model, httpClient, scope}) =>
                _NullChatClient(),
      ),
    );

  if (withTor) {
    services.addSingleton<TorSettings>(
      (sp) => TorSettings(
        kv,
        PlatformTorRuntime(
          platform: FakeTorPlatform(),
          identityStore: SecureOnionIdentityStore(InMemorySecretStore(), kv),
          options: TorOptions(),
        ),
      ),
    );
  }
  return services.buildServiceProvider();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Tor settings route', () {
    test('/settings/tor resolves', () {
      // A route declared in the wrong branch of the shell throws
      // "no routes for location" at runtime and nowhere else, so this is what
      // proves the Settings row leads somewhere.
      final match = _router(
        _buildServices(),
      ).configuration.findMatch(Uri.parse('/settings/tor'));

      expect(match.routes, isNotEmpty, reason: 'no routes for /settings/tor');
      expect(match.uri.path, '/settings/tor');
    });

    test('the pairing screen resolves from Settings', () {
      // The row added to Settings navigates here. The route already existed
      // but nothing led to it, so this pins the pair together.
      final match = _router(
        _buildServices(),
      ).configuration.findMatch(Uri.parse('/settings/network/pair'));

      expect(match.routes, isNotEmpty);
      expect(match.uri.path, '/settings/network/pair');
    });

    test('resolves alongside the other Settings pages', () {
      final router = _router(_buildServices());

      for (final location in const [
        '/settings',
        '/settings/tor',
        '/settings/network/pair',
        '/settings/web-search',
        '/settings/appearance',
      ]) {
        expect(
          router.configuration.findMatch(Uri.parse(location)).routes,
          isNotEmpty,
          reason: location,
        );
      }
    });
  });

  group('the Settings home rows', () {
    testWidgets('lists Pair with a device', (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Pumped directly rather than through the app: this asserts the row
      // exists, which is the thing that was missing, without dragging in
      // bootstrap.
      await tester.pumpWidget(
        MaterialApp(home: SettingsHomeScreen(services: _buildServices())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pair with a device'), findsOneWidget);
      expect(find.text('Tor'), findsOneWidget);
    });

    testWidgets('lists pairing even without a Tor backend', (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Consuming someone else's code is a client action and works over the
      // local network, so it must not be hidden behind Tor.
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsHomeScreen(services: _buildServices(withTor: false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pair with a device'), findsOneWidget);
      expect(find.text('Tor'), findsNothing);
    });
  });

  group('TorSettingsScreen', () {
    testWidgets('offers the switch when a backend is registered', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: TorSettingsScreen(services: _buildServices())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Enable Tor'), findsOneWidget);
    });

    testWidgets('explains itself when there is no backend', (tester) async {
      // Web registers no runtime, so the page has to say so rather than offer
      // a switch that cannot do anything.
      await tester.pumpWidget(
        MaterialApp(
          home: TorSettingsScreen(services: _buildServices(withTor: false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Enable Tor'), findsNothing);
      expect(find.textContaining('not available'), findsOneWidget);
    });
  });
}

final class _NullChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(messages: const <ai.ChatMessage>[]);

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => const Stream<ai.ChatResponseUpdate>.empty();

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

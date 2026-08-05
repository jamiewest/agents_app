// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart' show InMemoryAgentFileStore;
import 'package:agents_app/features/tor/secure_onion_identity_store.dart';
import 'package:agents_app/features/tor/tor_sharing_settings.dart';
import 'package:agents_app/ui/screens/agent_detail_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions/extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tor_flutter/tor_flutter.dart';
import 'package:tor_flutter/tor_flutter_testing.dart';

const _source = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);
const _model = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'fake-model',
);
const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Researcher',
  modelId: 'model-1',
  description: 'Finds things',
);

/// [testWidgets] with the platform pinned to macOS, where Tor hosting lives.
///
/// Hosting is macOS-only (see `TorSharingSettings.isSupported`) and the test
/// binding reports Android unless told otherwise, so every case in this file
/// needs the override. It has to be set and cleared inside the body: the
/// widget-test framework asserts every foundation debug variable is back to
/// its default before the body returns, which rules out `setUp`.
void testHostWidgets(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => 'wifi',
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success('wifi'),
      ),
    );
  });

  group('Tor sharing on the agent page', () {
    late InMemoryKeyValueStore kv;
    late ServiceProvider services;
    late NetworkSharingSettings network;
    late FakeTorPlatform platform;
    late InMemorySecretStore secrets;
    late SecureOnionIdentityStore identities;
    late TorSharingSettings tor;

    Future<void> seed() async {
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(_source);
      await manager.saveModel(_model);
      await manager.saveAgent(_agent);
    }

    setUp(() async {
      kv = InMemoryKeyValueStore();
      platform = FakeTorPlatform();
      secrets = InMemorySecretStore();
      identities = SecureOnionIdentityStore(secrets, kv);

      // Built once: buildServiceProvider seals the collection, so the two
      // settings objects have to be registered as factories rather than
      // constructed against a provider that does not exist yet.
      services =
          (ServiceCollection()
                ..addRecordStore(recordStore: (_) => InMemoryRecordStore())
                ..addSingleton<UsageStore>(
                  (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
                )
                ..addSingleton<AgentRunTelemetryStore>(
                  (sp) => AgentRunTelemetryStore(
                    sp.getRequiredService<RecordStore>(),
                  ),
                )
                ..addConfiguredAgents(
                  keyValueStore: (_) => kv,
                  secretStore: (_) => InMemorySecretStore(),
                  chatClientFactory: (_) => ConfiguredChatClientFactory(
                    customClientResolver:
                        ({
                          required source,
                          required model,
                          httpClient,
                          scope,
                        }) => _EchoChatClient(),
                  ),
                  configureHarness: (options) => options
                    ..disableAgentSkillsProvider = true
                    ..fileMemoryStore = InMemoryAgentFileStore()
                    ..fileAccessStore = InMemoryAgentFileStore()
                    ..enableConnectivity = false
                    ..enableTemporal = false
                    ..enableAppInfo = false
                    ..enableDeviceInfo = false,
                )
                ..addSingleton<NetworkSharingSettings>(
                  NetworkSharingSettings.new,
                )
                ..addSingleton<TorSharingSettings>(
                  (sp) => TorSharingSettings(
                    kv,
                    PlatformTorRuntime(
                      platform: platform,
                      identityStore: identities,
                      options: TorOptions(),
                    ),
                    sp.getRequiredService<NetworkSharingSettings>(),
                    identities,
                  ),
                ))
              .buildServiceProvider();

      await seed();
      network = services.getRequiredService<NetworkSharingSettings>();
      tor = services.getRequiredService<TorSharingSettings>();
    });

    tearDown(() {
      tor.dispose();
      network.dispose();
    });

    Widget host() => MaterialApp(
      home: AgentDetailScreen(
        services: services,
        agentId: _agent.id,
        now: () => DateTime(2026, 7, 23, 12),
      ),
    );

    /// Starts real sharing, renders, then shuts it down again.
    ///
    /// The host is a real socket and the Tor fake a real SOCKS server, so both
    /// have to start and stop inside [WidgetTester.runAsync] — widget tests
    /// run on fake async and refuse to finish with a live timer pending.
    Future<void> render(
      WidgetTester tester, {
      bool shared = false,
      bool overTor = false,
    }) async {
      await tester.runAsync(() async {
        if (shared) await network.setShared(_agent.id, true);
        if (overTor) await tor.setEnabled(true);
      });
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      addTearDown(
        () => tester.runAsync(() async {
          await tor.setEnabled(false);
          await network.setShared(_agent.id, false);
          await platform.dispose();
        }),
      );
    }

    testHostWidgets('is hidden until the agent is shared at all', (
      tester,
    ) async {
      await render(tester);

      expect(find.text('Share over Tor'), findsNothing);
    });

    testHostWidgets('appears once the agent is shared', (tester) async {
      await render(tester, shared: true);

      expect(find.text('Share over Tor'), findsOneWidget);
      expect(find.text('Show Tor pairing code'), findsNothing);
    });

    // A backgrounded iPhone is suspended, so an onion address it published
    // would be unreachable almost all of the time. The switch stays off iOS
    // rather than shipping a feature that cannot work.
    testWidgets('stays hidden on iOS even when the agent is shared', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await render(tester, shared: true);

        expect(find.text('Share over Tor'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testHostWidgets('shows the onion address once published', (tester) async {
      await render(tester, shared: true, overTor: true);

      expect(find.textContaining('.onion'), findsOneWidget);
      expect(find.text('Show Tor pairing code'), findsOneWidget);
    });

    testHostWidgets('says the LAN is no longer serving while Tor is on', (
      tester,
    ) async {
      await render(tester, shared: true, overTor: true);

      // The port is still bound, so a subtitle naming it would read as
      // "reachable here" when nothing on this network can reach it.
      expect(
        find.text('Reachable over Tor only — not served on this network'),
        findsOneWidget,
      );
    });

    /// Loses the key while the index that lists it survives — a keychain wipe,
    /// or a restore that brought preferences across but not the keychain.
    Future<void> loseTheKey() async {
      await identities.write(
        OnionIdentityRecord(
          id: TorSharingSettings.identityId,
          address: 'oldaddress.onion',
          secretKey: Uint8List.fromList(List.generate(64, (i) => i)),
        ),
      );
      await secrets.delete(
        'agents_app.tor.identity.${TorSharingSettings.identityId}',
      );
      await tor.load();
    }

    /// The card sits below the fold on a test-sized viewport, so the button
    /// has to be scrolled to before it can be hit.
    Future<void> tapReset(WidgetTester tester) async {
      final button = find.widgetWithText(OutlinedButton, 'Reset Tor identity');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testHostWidgets('offers a way out when the identity key is lost', (
      tester,
    ) async {
      await tester.runAsync(loseTheKey);
      await render(tester, shared: true);

      expect(find.text('Reset Tor identity'), findsOneWidget);
      // A switch that can still be tapped spends a full bootstrap failing and
      // then flips itself back, which is the trap this replaces.
      final switchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Share over Tor'),
      );
      expect(switchTile.onChanged, isNull);
    });

    testHostWidgets('does not reset on a single tap', (tester) async {
      await tester.runAsync(loseTheKey);
      await render(tester, shared: true);

      await tapReset(tester);

      // Confirmation first: the cost lands on the user's peers, and nothing
      // can undo it.
      expect(find.text('Reset Tor identity?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tor.isIdentityUnrecoverable, isTrue);
      expect(find.text('Reset Tor identity'), findsOneWidget);
    });

    testHostWidgets('clears the wedge once confirmed', (tester) async {
      await tester.runAsync(loseTheKey);
      await render(tester, shared: true);

      await tapReset(tester);
      await tester.tap(find.text('Reset identity'));
      await tester.pumpAndSettle();

      expect(tor.isIdentityUnrecoverable, isFalse);
      expect(find.text('Reset Tor identity'), findsNothing);
      // The dead address goes with it; leaving it on screen would suggest it
      // still meant something.
      expect(find.text('oldaddress.onion'), findsNothing);
      final switchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Share over Tor'),
      );
      expect(switchTile.onChanged, isNotNull);
    });

    testHostWidgets('keeps showing the address after sharing is turned off', (
      tester,
    ) async {
      await render(tester, shared: true, overTor: true);
      final address = tor.address;
      await tester.runAsync(() => tor.setEnabled(false));
      await tester.pumpAndSettle();

      // Still the identity the user handed out; blanking it would suggest it
      // had changed.
      expect(find.text(address!), findsOneWidget);
    });
  });
}

final class _EchoChatClient extends ai.ChatClient {
  @override
  Future<ai.ChatResponse> getResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) async => ai.ChatResponse(
    messages: <ai.ChatMessage>[
      ai.ChatMessage.fromText(ai.ChatRole.assistant, 'ok'),
    ],
  );

  @override
  Stream<ai.ChatResponseUpdate> getStreamingResponse({
    required Iterable<ai.ChatMessage> messages,
    ai.ChatOptions? options,
    CancellationToken? cancellationToken,
  }) => Stream<ai.ChatResponseUpdate>.value(
    ai.ChatResponseUpdate.fromText(ai.ChatRole.assistant, 'ok'),
  );

  @override
  T? getService<T>({Object? key}) => null;

  @override
  void dispose() {}
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/add_agent_wizard.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/chat_test_harness.dart';

GoRouter _buildRouter(ServiceProvider services, {AgentSetupKind? kind}) =>
    GoRouter(
      initialLocation: '/settings/agents/add',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('settings')),
          routes: [
            GoRoute(
              path: 'agents/add',
              builder: (context, state) =>
                  AddAgentWizard(services: services, initialKind: kind),
            ),
            GoRoute(
              path: 'network/pair',
              builder: (context, state) => const Scaffold(body: Text('pair')),
            ),
          ],
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installConnectivityMocks);

  group('AddAgentWizard', () {
    testWidgets('asks for the agent kind when none is preselected', (
      tester,
    ) async {
      final services = buildTestServices(InMemoryRecordStore());
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: _buildRouter(services)),
      );
      await tester.pumpAndSettle();

      expect(find.text('API agent'), findsOneWidget);
      expect(find.text('Local agent'), findsOneWidget);
      expect(find.text('Network agent'), findsOneWidget);
    });

    testWidgets('API kind starts at Provider without local llama', (
      tester,
    ) async {
      final services = buildTestServices(InMemoryRecordStore());
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: _buildRouter(services, kind: AgentSetupKind.api),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add agent — Provider'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<ProviderType>));
      await tester.pumpAndSettle();
      expect(find.text('Local llama'), findsNothing);
      expect(find.text('Anthropic'), findsWidgets);
    });

    testWidgets('local kind skips the provider step and creates a source', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: _buildRouter(services, kind: AgentSetupKind.local),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add agent — Model'), findsOneWidget);
      expect(find.text('Start from a known-good model'), findsOneWidget);

      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      final sources = await manager.sources.listSources();
      expect(sources, hasLength(1));
      expect(sources.single.providerType, ProviderType.localLlama);
    });

    testWidgets('local kind reuses an existing local source', (tester) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await manager.saveSource(testSource);

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: _buildRouter(services, kind: AgentSetupKind.local),
        ),
      );
      await tester.pumpAndSettle();

      final sources = await manager.sources.listSources();
      expect(sources, hasLength(1));
      expect(sources.single.id, testSource.id);
    });

    testWidgets('chooser network option routes to pairing', (tester) async {
      final services = buildTestServices(InMemoryRecordStore());
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: _buildRouter(services)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Network agent'));
      await tester.pumpAndSettle();

      expect(find.text('pair'), findsOneWidget);
    });
  });
}

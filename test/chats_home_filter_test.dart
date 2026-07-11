// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/conversation_store.dart';
import 'package:agents_app/domain/chats_filter.dart';
import 'package:agents_app/main.dart' show ChatScreen;
import 'package:agents_app/ui/widgets/chats_filter_sheet.dart';
import 'package:agents_app/ui/screens/chats_home.dart'
    show ChatDetailPane, ChatsHome, ChatsListView, ChatsRootPane, ChatsScope;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/chat_test_harness.dart';

const _localSource = ModelSourceConfig(
  id: 'src-local',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);

const _apiSource = ModelSourceConfig(
  id: 'src-api',
  providerType: ProviderType.anthropic,
  displayName: 'Hosted',
);

const _plainModel = ModelConfig(
  id: 'model-plain',
  sourceId: 'src-local',
  modelId: 'plain-model',
);

const _visionModel = ModelConfig(
  id: 'model-vision',
  sourceId: 'src-api',
  modelId: 'vision-model',
  settings: {ModelCapabilities.visionKey: 'true'},
);

const _plainAgent = SavedAgentConfig(
  id: 'agent-plain',
  name: 'Plain Agent',
  modelId: 'model-plain',
);

const _visionAgent = SavedAgentConfig(
  id: 'agent-vision',
  name: 'Vision Agent',
  modelId: 'model-vision',
);

GoRouter _buildRouter(ServiceProvider services, {String initial = '/chats'}) =>
    GoRouter(
      initialLocation: initial,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) =>
              ChatsHome(services: services, navigationShell: navigationShell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/chats',
                  builder: (context, state) =>
                      ChatsRootPane(services: services),
                  routes: [
                    GoRoute(
                      path: 'c/:conversationId',
                      builder: (context, state) => ChatDetailPane(
                        services: services,
                        conversationId: state.pathParameters['conversationId'],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

Widget _host(GoRouter router) => MaterialApp.router(routerConfig: router);

/// Seeds two agents on distinct execution/capability profiles and one
/// conversation for each.
Future<ServiceProvider> _seededServices(InMemoryRecordStore records) async {
  final services = buildTestServices(records);
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(_localSource);
  await manager.saveSource(_apiSource);
  await manager.saveModel(_plainModel);
  await manager.saveModel(_visionModel);
  await manager.saveAgent(_plainAgent);
  await manager.saveAgent(_visionAgent);
  final store = ConversationStore(records);
  await store.save(
    testConversation(
      id: 'alpha-chat',
      title: 'Alpha topic',
      agentId: 'agent-plain',
      updatedAt: DateTime.utc(2026, 6, 30, 9),
      preview: 'plain preview',
    ),
  );
  await store.save(
    testConversation(
      id: 'beta-chat',
      title: 'Beta topic',
      agentId: 'agent-vision',
      updatedAt: DateTime.utc(2026, 6, 30, 12),
    ),
  );
  return services;
}

Finder _searchField() => find.descendant(
  of: find.byType(ChatsListView),
  matching: find.byType(TextField),
);

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(_searchField(), text);
  await tester.pumpAndSettle();
}

Future<void> _openFilterSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Filter and sort'));
  await tester.pumpAndSettle();
}

Finder _sheetChip(String label) =>
    find.descendant(of: find.byType(FilterChip), matching: find.text(label));

/// Taps a chip inside the filter sheet, scrolling its lazy list first so
/// sections below the fold (capabilities, execution, sort) are reachable.
Future<void> _tapSheetChip(WidgetTester tester, String label) async {
  final chip = _sheetChip(label);
  await tester.scrollUntilVisible(
    chip,
    80,
    scrollable: find
        .descendant(
          of: find.byType(ChatsFilterSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Future<void> _applyFilters(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installConnectivityMocks);

  group('chats list search', () {
    testWidgets('filters and auto-expands matching sections on the page', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      // Sections start collapsed: headers visible, tiles hidden.
      expect(find.text('Plain Agent'), findsOneWidget);
      expect(find.text('Vision Agent'), findsOneWidget);
      expect(find.text('Alpha topic'), findsNothing);

      await _search(tester, 'ALPHA');

      // The matching section auto-expands; the empty section is removed.
      expect(find.text('Alpha topic'), findsOneWidget);
      expect(find.text('Vision Agent'), findsNothing);
      expect(find.text('Beta topic'), findsNothing);
    });

    testWidgets('restores the saved section state when cleared', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      // The user expands Vision Agent; Plain Agent stays collapsed.
      await tester.tap(find.text('Vision Agent'));
      await tester.pumpAndSettle();
      expect(find.text('Beta topic'), findsOneWidget);

      await _search(tester, 'alpha');
      expect(find.text('Beta topic'), findsNothing);
      expect(find.text('Alpha topic'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      // Previous choices return: Vision open, Plain still collapsed.
      expect(find.text('Beta topic'), findsOneWidget);
      expect(find.text('Alpha topic'), findsNothing);
    });

    testWidgets('shows the no-match state with a working clear action', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _search(tester, 'zzz-no-such-chat');

      expect(find.text('No matching conversations'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Clear search and filters'),
      );
      await tester.pumpAndSettle();

      expect(find.text('No matching conversations'), findsNothing);
      expect(find.text('Plain Agent'), findsOneWidget);
      expect(find.text('Vision Agent'), findsOneWidget);
      expect(
        tester.widget<TextField>(_searchField()).controller!.text,
        isEmpty,
      );
    });

    testWidgets('keeps the first-use empty state without search controls', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = buildTestServices(records);
      await seedTestAgent(services);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      expect(find.text('No conversations yet'), findsOneWidget);
      expect(_searchField(), findsNothing);
    });
  });

  group('chats list filters', () {
    testWidgets('filters by agent with a badge and removable chip', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _openFilterSheet(tester);
      await _tapSheetChip(tester, 'Plain Agent');
      await _applyFilters(tester);

      expect(find.text('Alpha topic'), findsOneWidget);
      expect(find.text('Vision Agent'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(InputChip),
          matching: find.text('Plain Agent'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(Badge), matching: find.text('1')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Remove filter'));
      await tester.pumpAndSettle();
      expect(find.text('Vision Agent'), findsOneWidget);
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('filters by capability', (tester) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _openFilterSheet(tester);
      await _tapSheetChip(tester, 'Vision');
      await _applyFilters(tester);

      expect(find.text('Beta topic'), findsOneWidget);
      expect(find.text('Plain Agent'), findsNothing);
    });

    testWidgets('filters by execution type', (tester) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _openFilterSheet(tester);
      await _tapSheetChip(tester, 'On-device');
      await _applyFilters(tester);

      expect(find.text('Alpha topic'), findsOneWidget);
      expect(find.text('Vision Agent'), findsNothing);
    });

    testWidgets('configuration changes refresh the filtered results', (
      tester,
    ) async {
      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      await _openFilterSheet(tester);
      await _tapSheetChip(tester, 'Vision');
      await _applyFilters(tester);
      expect(find.text('Beta topic'), findsOneWidget);

      // Editing the model to drop vision must re-filter without a remount.
      final manager = services.getRequiredService<ConfiguredAgentsManager>();
      await tester.runAsync(
        () => manager.saveModel(
          const ModelConfig(
            id: 'model-vision',
            sourceId: 'src-api',
            modelId: 'vision-model',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Beta topic'), findsNothing);
      expect(find.text('No matching conversations'), findsOneWidget);
    });

    testWidgets('lays out without overflow at narrow widths', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      // Activate every chip-producing filter through the shared controller
      // so the active-chips row renders at its widest.
      final scope = tester.widget<ChatsScope>(find.byType(ChatsScope));
      scope.filters!.query = const ChatsQuery(
        searchText: 'topic',
        agentIds: {'agent-plain', 'agent-vision'},
        activity: ChatsActivityFilter.last30Days,
        capabilities: {ChatsCapabilityFilter.tools},
        executionTypes: {ChatsExecutionType.local, ChatsExecutionType.api},
      );
      await tester.pumpAndSettle();

      expect(find.byType(InputChip), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('chats sidebar', () {
    testWidgets('keeps search state across sidebar collapse and restore', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(_host(_buildRouter(services)));
      await tester.pumpAndSettle();

      expect(_searchField(), findsOneWidget);
      await _search(tester, 'alpha');
      expect(find.text('Alpha topic'), findsOneWidget);
      expect(find.text('Vision Agent'), findsNothing);

      await tester.tap(find.byTooltip('Hide conversations'));
      await tester.pumpAndSettle();
      expect(_searchField(), findsNothing);

      await tester.tap(find.byTooltip('Show conversations'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(_searchField()).controller!.text,
        'alpha',
      );
      expect(find.text('Alpha topic'), findsOneWidget);
      expect(find.text('Vision Agent'), findsNothing);
    });

    testWidgets('keeps the open conversation when it is filtered out', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final records = InMemoryRecordStore();
      final services = await _seededServices(records);
      await tester.pumpWidget(
        _host(_buildRouter(services, initial: '/chats/c/beta-chat')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);

      await _search(tester, 'alpha');

      // The open chat's section is hidden from the sidebar (the detail
      // pane may still show the agent name), but the route stays put.
      expect(
        find.descendant(
          of: find.byType(ChatsListView),
          matching: find.text('Vision Agent'),
        ),
        findsNothing,
      );
      expect(find.byType(ChatScreen), findsOneWidget);
    });
  });
}

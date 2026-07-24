// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/agent_center_nav.dart';
import 'package:agents_app/ui/screens/agent_center_screen.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = ModelSourceConfig(
  id: 'source-1',
  providerType: ProviderType.openAiCompatible,
  displayName: 'My provider',
  endpoint: 'https://example.test/v1',
);
const _model = ModelConfig(
  id: 'model-1',
  sourceId: 'source-1',
  modelId: 'gpt-test',
  displayName: 'Test model',
);
const _agent = SavedAgentConfig(
  id: 'agent-1',
  name: 'Researcher',
  modelId: 'model-1',
  description: 'Finds things',
);

/// Widths that select each layout the screen supports.
const _compact = Size(420, 900);
const _medium = Size(900, 900);
const _wide = Size(1400, 1000);

ServiceProvider _services() =>
    (ServiceCollection()..addConfiguredAgents(
          keyValueStore: (_) => InMemoryKeyValueStore(),
          secretStore: (_) => InMemorySecretStore(),
        ))
        .buildServiceProvider();

ConfiguredAgentsManager _manager(ServiceProvider services) =>
    services.getRequiredService<ConfiguredAgentsManager>();

Future<void> _seed(
  ServiceProvider services, {
  bool source = true,
  bool model = true,
  bool agent = true,
}) async {
  final manager = _manager(services);
  if (source) await manager.saveSource(_source);
  if (model) await manager.saveModel(_model);
  if (agent) await manager.saveAgent(_agent);
}

/// The text input of the editor field labelled [label].
///
/// The label is a sibling of the input rather than an `InputDecoration`
/// label, so it has to be reached through the shared field wrapper.
Finder _field(String label) => find.descendant(
  of: find.widgetWithText(ConfiguredAgentsFormField, label),
  matching: find.byType(TextFormField),
);

Widget _host(
  ServiceProvider services, {
  AgentCenterSection section = AgentCenterSection.agents,
  String? editingId,
  bool creating = false,
}) => MaterialApp(
  home: AgentCenterScreen(
    services: services,
    section: section,
    editingId: editingId,
    creating: creating,
  ),
);

extension on WidgetTester {
  /// Sizes the surface, then pumps [widget] and settles.
  Future<void> pumpAt(Size size, Widget widget) async {
    view.physicalSize = size;
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
    await pumpWidget(widget);
    await pumpAndSettle();
  }
}

void main() {
  group('catalogs', () {
    testWidgets('agents list shows name and description', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services));

      expect(find.text('Researcher'), findsOneWidget);
      expect(find.text('Finds things'), findsOneWidget);
    });

    testWidgets('models list shows the label and its source', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.models),
      );

      expect(find.text('Test model'), findsOneWidget);
      expect(find.text('My provider'), findsOneWidget);
    });

    testWidgets('sources list shows the provider and endpoint', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.sources),
      );

      expect(find.text('My provider'), findsOneWidget);
      expect(find.textContaining('https://example.test/v1'), findsOneWidget);
    });

    testWidgets('search filters the list once it is long enough', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);
      final manager = _manager(services);
      for (var i = 0; i < 6; i++) {
        await manager.saveAgent(
          SavedAgentConfig(id: 'a$i', name: 'Agent $i', modelId: 'model-1'),
        );
      }

      await tester.pumpAt(_medium, _host(services));
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Agent 3');
      await tester.pumpAndSettle();

      Finder inList(String text) =>
          find.descendant(of: find.byType(ListView), matching: find.text(text));
      expect(inList('Agent 3'), findsOneWidget);
      expect(inList('Agent 4'), findsNothing);
      expect(inList('Researcher'), findsNothing);
    });

    testWidgets('short lists get no search field', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services));

      expect(find.byType(TextField), findsNothing);
    });
  });

  group('prerequisites', () {
    testWidgets('adding an agent is blocked until a model exists', (
      tester,
    ) async {
      final services = _services();
      await _seed(services, model: false, agent: false);

      await tester.pumpAt(_medium, _host(services));

      expect(find.textContaining('model'), findsWidgets);
      // The wizard is the way out of every dead end.
      expect(find.text('Guided setup'), findsOneWidget);
      final add = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Add agent'),
          matching: find.byType(IconButton),
        ),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('adding a model is blocked until a source exists', (
      tester,
    ) async {
      final services = _services();

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.models),
      );

      expect(find.text('Add a source before adding a model.'), findsOneWidget);
    });

    testWidgets('sources have no prerequisite and can always be added', (
      tester,
    ) async {
      final services = _services();

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.sources),
      );

      final add = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Add source'),
          matching: find.byType(IconButton),
        ),
      );
      expect(add.onPressed, isNotNull);
    });
  });

  group('editors', () {
    testWidgets('a route-supplied id opens that item for editing', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services, editingId: 'agent-1'));

      final editor = tester.widget<AgentEditor>(find.byType(AgentEditor));
      expect(editor.initial?.name, 'Researcher');
    });

    testWidgets('creating opens an empty form', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services, creating: true));

      expect(
        tester.widget<AgentEditor>(find.byType(AgentEditor)).initial,
        isNull,
      );
    });

    testWidgets('saving an edit persists it and closes the editor', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      // Tall enough that the whole agent form, Save included, is on screen.
      await tester.pumpAt(
        const Size(1400, 2600),
        _host(services, editingId: 'agent-1'),
      );
      await tester.enterText(_field('Name'), 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = await _manager(services).agents.getAgent('agent-1');
      expect(saved?.name, 'Renamed');
      expect(find.byType(AgentEditor), findsNothing);
    });

    testWidgets('the source editor carries the web key-storage notice', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        _wide,
        _host(
          services,
          section: AgentCenterSection.sources,
          editingId: 'source-1',
        ),
      );

      expect(find.byType(WebKeyStorageNotice), findsOneWidget);
      expect(find.textContaining('secure storage'), findsOneWidget);
    });
  });

  group('unsaved edits', () {
    testWidgets('closing a dirty editor asks before discarding', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_wide, _host(services, editingId: 'agent-1'));
      await tester.enterText(_field('Name'), 'Changed');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditor), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentEditor), findsNothing);
    });

    testWidgets('closing an untouched editor asks nothing', (tester) async {
      // Confirming a no-op is exactly the prompt the app's UI rules forbid.
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_wide, _host(services, editingId: 'agent-1'));
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(AgentEditor), findsNothing);
    });

    testWidgets('switching selection with unsaved edits asks first', (
      tester,
    ) async {
      // The inline editor + tap-to-switch flow is a models/sources thing;
      // agents open a detail page on tap instead. Use sources here.
      final services = _services();
      await _seed(services);
      await _manager(services).saveSource(
        const ModelSourceConfig(
          id: 'source-2',
          providerType: ProviderType.openAiCompatible,
          displayName: 'Other provider',
        ),
      );

      await tester.pumpAt(
        _wide,
        _host(
          services,
          section: AgentCenterSection.sources,
          editingId: 'source-1',
        ),
      );
      await tester.enterText(_field('Display name'), 'Changed');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('Other provider'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('deleting asks first and then removes the item', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services));
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm delete'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await _manager(services).agents.listAgents(), isEmpty);
    });

    testWidgets('cancelling the confirmation keeps the item', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services));
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await _manager(services).agents.listAgents(), hasLength(1));
    });

    testWidgets('a blocked delete offers to cascade', (tester) async {
      // The model is in use by an agent, so the manager refuses and explains.
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.models),
      );
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete anyway'), findsOneWidget);
      await tester.tap(find.text('Delete anyway'));
      await tester.pumpAndSettle();

      expect(await _manager(services).sources.listModels(), isEmpty);
      // Cascade took the dependent agent with it.
      expect(await _manager(services).agents.listAgents(), isEmpty);
    });

    testWidgets('declining the cascade leaves everything in place', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(
        _medium,
        _host(services, section: AgentCenterSection.models),
      );
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await _manager(services).sources.listModels(), hasLength(1));
      expect(await _manager(services).agents.listAgents(), hasLength(1));
    });
  });

  group('layout', () {
    testWidgets('wide layouts show the editor beside the list', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_wide, _host(services, editingId: 'agent-1'));

      // Both panes are on screen at once, side by side.
      expect(find.text('Researcher'), findsWidgets);
      expect(find.byType(AgentEditor), findsOneWidget);
      final list = tester.getTopLeft(find.byType(ListView));
      final editor = tester.getTopLeft(find.byType(AgentEditor));
      expect(editor.dx, greaterThan(list.dx));
    });

    testWidgets('narrow layouts give the editor its own page', (tester) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_compact, _host(services, editingId: 'agent-1'));

      expect(find.byType(AgentEditor), findsOneWidget);
      // The list is not sharing the screen with it.
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('the section switcher is horizontal only when narrow', (
      tester,
    ) async {
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_compact, _host(services));
      expect(find.byType(SegmentedButton<AgentCenterTab>), findsOneWidget);

      await tester.pumpAt(_medium, _host(services));
      expect(find.byType(SegmentedButton<AgentCenterTab>), findsNothing);
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
    });
  });

  group('external changes', () {
    testWidgets('the list picks up configuration saved elsewhere', (
      tester,
    ) async {
      // The wizard, a chat-side edit, or a cascade delete all mutate
      // configuration behind this screen.
      final services = _services();
      await _seed(services);

      await tester.pumpAt(_medium, _host(services));
      expect(find.text('Added later'), findsNothing);

      await _manager(services).saveAgent(
        const SavedAgentConfig(
          id: 'agent-9',
          name: 'Added later',
          modelId: 'model-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Added later'), findsOneWidget);
    });
  });
}

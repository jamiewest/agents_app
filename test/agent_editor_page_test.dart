// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/agent_center_nav.dart';
import 'package:agents_app/ui/screens/agent_editor_page.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceProvider _services() =>
    (ServiceCollection()..addConfiguredAgents(
          keyValueStore: (_) => InMemoryKeyValueStore(),
          secretStore: (_) => InMemorySecretStore(),
        ))
        .buildServiceProvider();

Future<ServiceProvider> _seeded() async {
  final services = _services();
  final manager = services.getRequiredService<ConfiguredAgentsManager>();
  await manager.saveSource(
    const ModelSourceConfig(
      id: 's1',
      providerType: ProviderType.openAiCompatible,
      displayName: 'Prov',
    ),
  );
  // A model id the format detector recognizes, so _refreshDetection fires.
  await manager.saveModel(
    const ModelConfig(id: 'm1', sourceId: 's1', modelId: 'llama-3.1-8b'),
  );
  return services;
}

Widget _host(ServiceProvider services) => MaterialApp(
  home: Navigator(
    onGenerateInitialRoutes: (navigator, initial) => [
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('base'))),
      ),
      MaterialPageRoute<void>(
        builder: (_) => AgentEditorPage(
          services: services,
          kind: AgentCenterTab.models,
          editingId: 'm1',
        ),
      ),
    ],
  ),
);

void main() {
  testWidgets('opening the model editor for a named model does not crash', (
    tester,
  ) async {
    await tester.pumpWidget(_host(await _seeded()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening then backing out does not prompt to discard', (
    tester,
  ) async {
    await tester.pumpWidget(_host(await _seeded()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // No spurious dirty from format detection: closed with no prompt.
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(AgentEditorPage), findsNothing);
  });

  testWidgets('a real edit marks the form dirty and guards it', (tester) async {
    await tester.pumpWidget(_host(await _seeded()));
    await tester.pumpAndSettle();

    final name = find.descendant(
      of: find.widgetWithText(ConfiguredAgentsFormField, 'Model id'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(name, 'Edited');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsOneWidget);
  });
}

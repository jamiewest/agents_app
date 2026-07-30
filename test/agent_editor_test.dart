// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/chat_toolkit/strings/configured_agents_strings.dart';
import 'package:agents_app/chat_toolkit/styles/configured_agents_style.dart';
import 'package:agents_app/chat_toolkit/views/configured_agents/agent_editor.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = ModelConfig(id: 'm1', sourceId: 's1', modelId: 'llama-3.1-8b');

Widget _host({
  SavedAgentConfig? initial,
  required ValueChanged<SavedAgentConfig> onSubmit,
  bool? inventoryEnabled,
  void Function(String agentId, bool enabled)? onInventoryEnabled,
  PushoverSettings? pushoverSettings,
  VoidCallback? onConfigurePushover,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Builder(
        builder: (context) => AgentEditor(
          initial: initial,
          models: const [_model],
          style: ConfiguredAgentsStyle.resolveFor(context, null),
          strings: ConfiguredAgentsStrings.defaults,
          initialInventoryEnabled: inventoryEnabled,
          onInventoryEnabled: onInventoryEnabled,
          pushoverSettings: pushoverSettings,
          onConfigurePushover: onConfigurePushover,
          onSubmit: onSubmit,
          onCancel: () {},
        ),
      ),
    ),
  ),
);

/// Every tool/context capability an [AgentAccessConfig] can grant.
List<bool> _grants(AgentAccessConfig access) => [
  access.enableFileMemory,
  access.enableFileAccess,
  access.enableFileWriteTools,
  access.enableWebSearch,
  access.enableShell,
  access.enableTodoList,
  access.enableAgentMode,
  access.enableSkills,
  access.enableTemporal,
  access.enableConnectivity,
  access.enableAppInfo,
  access.enableDeviceInfo,
  access.enableLocation,
  access.enableNetworkInfo,
  access.enableWakeLock,
  access.enablePushover,
];

Future<SavedAgentConfig> _save(
  WidgetTester tester, {
  SavedAgentConfig? initial,
}) async {
  SavedAgentConfig? submitted;
  await tester.pumpWidget(
    _host(initial: initial, onSubmit: (agent) => submitted = agent),
  );
  // The name field is the first field in the editor's form.
  await tester.enterText(find.byType(TextFormField).first, 'Test agent');
  // The tall form clips the save row out of the test viewport, so invoke
  // the button directly instead of scrolling and tapping.
  final save = find.widgetWithText(FilledButton, 'Save');
  tester.widget<FilledButton>(save).onPressed!();
  await tester.pump();
  expect(submitted, isNotNull);
  return submitted!;
}

void main() {
  testWidgets('a new agent saves with every tool disabled', (tester) async {
    final agent = await _save(tester);
    final access = agent.access;
    expect(access, isNotNull);
    expect(_grants(access!), everyElement(isFalse));
  });

  testWidgets('a legacy agent without an access record keeps the '
      'package defaults', (tester) async {
    final agent = await _save(
      tester,
      initial: const SavedAgentConfig(
        id: 'legacy',
        name: 'Legacy',
        modelId: 'm1',
      ),
    );
    // The runtime treats a missing record as AgentAccessConfig(), so the
    // editor must not silently disable a legacy agent's tools on save.
    expect(agent.access, isNotNull);
    expect(_grants(agent.access!), _grants(const AgentAccessConfig()));
  });

  testWidgets('the inventory switch is hidden without an inventory host', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onSubmit: (_) {}));
    expect(find.widgetWithText(SwitchListTile, 'Inventory'), findsNothing);
  });

  testWidgets('the inventory choice reaches the host on submit', (
    tester,
  ) async {
    SavedAgentConfig? submitted;
    (String, bool)? reported;
    await tester.pumpWidget(
      _host(
        inventoryEnabled: false,
        onInventoryEnabled: (agentId, enabled) => reported = (agentId, enabled),
        onSubmit: (agent) => submitted = agent,
      ),
    );
    await tester.enterText(find.byType(TextFormField).first, 'Test agent');
    // The tall form clips the switch and the save row out of the test
    // viewport, so invoke their callbacks directly.
    final inventorySwitch = find.widgetWithText(SwitchListTile, 'Inventory');
    tester.widget<SwitchListTile>(inventorySwitch).onChanged!(true);
    await tester.pump();
    final save = find.widgetWithText(FilledButton, 'Save');
    tester.widget<FilledButton>(save).onPressed!();
    await tester.pump();
    expect(submitted, isNotNull);
    expect(reported, (submitted!.id, true));
  });

  group('pushover not-configured warning', () {
    final warning = find.textContaining("Pushover isn't configured");

    Future<PushoverSettings> pumpWithPushover(
      WidgetTester tester, {
      VoidCallback? onConfigure,
    }) async {
      final settings = PushoverSettings(InMemorySecretStore());
      await settings.load();
      await tester.pumpWidget(
        _host(
          onSubmit: (_) {},
          pushoverSettings: settings,
          onConfigurePushover: onConfigure,
        ),
      );
      return settings;
    }

    /// Turns the Pushover access switch on; the tall form clips it out of
    /// the test viewport, so its callback is invoked directly.
    Future<void> enablePushover(WidgetTester tester) async {
      final pushoverSwitch = find.widgetWithText(
        SwitchListTile,
        'Pushover notifications',
      );
      tester.widget<SwitchListTile>(pushoverSwitch).onChanged!(true);
      await tester.pump();
    }

    testWidgets('appears only while the switch is on', (tester) async {
      await pumpWithPushover(tester);
      expect(warning, findsNothing);

      await enablePushover(tester);
      expect(warning, findsOneWidget);
    });

    testWidgets('stays hidden when credentials are stored', (tester) async {
      final settings = await pumpWithPushover(tester);
      await settings.save(token: 't', user: 'u');
      await enablePushover(tester);
      expect(warning, findsNothing);
    });

    testWidgets('clears itself when credentials arrive', (tester) async {
      final settings = await pumpWithPushover(tester);
      await enablePushover(tester);
      expect(warning, findsOneWidget);

      await settings.save(token: 't', user: 'u');
      await tester.pump();
      expect(warning, findsNothing);
    });

    testWidgets('offers the configure action', (tester) async {
      var configureRequests = 0;
      await pumpWithPushover(tester, onConfigure: () => configureRequests++);
      await enablePushover(tester);

      final action = find.widgetWithText(TextButton, 'Add credentials');
      expect(action, findsOneWidget);
      tester.widget<TextButton>(action).onPressed!();
      expect(configureRequests, 1);
    });
  });
}

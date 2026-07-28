// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/strings/configured_agents_strings.dart';
import 'package:agents_app/ui/styles/configured_agents_style.dart';
import 'package:agents_app/ui/views/configured_agents/agent_editor.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = ModelConfig(id: 'm1', sourceId: 's1', modelId: 'llama-3.1-8b');

Widget _host({
  SavedAgentConfig? initial,
  required ValueChanged<SavedAgentConfig> onSubmit,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Builder(
        builder: (context) => AgentEditor(
          initial: initial,
          models: const [_model],
          style: ConfiguredAgentsStyle.resolveFor(context, null),
          strings: ConfiguredAgentsStrings.defaults,
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
}

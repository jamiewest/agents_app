// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/chat_toolkit/strings/configured_agents_strings.dart';
import 'package:agents_app/chat_toolkit/styles/configured_agents_style.dart';
import 'package:agents_app/chat_toolkit/views/configured_agents/source_editor.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _editor({
  ModelSourceConfig? initial,
  void Function(ModelSourceConfig source, String? apiKey)? onSubmit,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SourceEditor(
        initial: initial,
        hasStoredKey: initial != null,
        style: const ConfiguredAgentsStyle(),
        strings: const ConfiguredAgentsStrings(),
        onSubmit: onSubmit ?? (_, _) {},
        onCancel: () {},
      ),
    ),
  ),
);

/// The editor's fields, in the order the form lays them out.
final _displayNameField = find.byType(TextFormField).at(0);
final _apiKeyField = find.byType(TextFormField).at(2);

/// The text currently in the display-name field.
String _displayNameOf(WidgetTester tester) =>
    tester.widget<TextFormField>(_displayNameField).controller!.text;

/// Opens the provider dropdown and picks [label].
Future<void> _selectProvider(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<ProviderType>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('SourceEditor provider dropdown', () {
    testWidgets('names an unnamed source after the chosen provider', (
      tester,
    ) async {
      ModelSourceConfig? saved;
      await tester.pumpWidget(_editor(onSubmit: (source, _) => saved = source));

      await _selectProvider(tester, 'Anthropic');

      expect(_displayNameOf(tester), 'Anthropic');

      await tester.enterText(_apiKeyField, 'sk-test');
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved?.displayName, 'Anthropic');
    });

    testWidgets('keeps following the dropdown while the name is its own', (
      tester,
    ) async {
      await tester.pumpWidget(_editor());

      await _selectProvider(tester, 'Anthropic');
      await _selectProvider(tester, 'Google (Gemini)');

      expect(_displayNameOf(tester), 'Google (Gemini)');
    });

    testWidgets('leaves a stored display name alone', (tester) async {
      ModelSourceConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: const ModelSourceConfig(
            id: 'src-1',
            providerType: ProviderType.anthropic,
            displayName: 'My work key',
          ),
          onSubmit: (source, _) => saved = source,
        ),
      );

      await _selectProvider(tester, 'Google (Gemini)');

      expect(_displayNameOf(tester), 'My work key');

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.providerType, ProviderType.google);
      expect(saved!.displayName, 'My work key');
    });

    testWidgets('leaves a name the user typed alone', (tester) async {
      await tester.pumpWidget(_editor());

      await _selectProvider(tester, 'Anthropic');
      await tester.enterText(_displayNameField, 'Scratch key');
      await tester.pump();

      await _selectProvider(tester, 'Google (Gemini)');

      expect(_displayNameOf(tester), 'Scratch key');
    });

    testWidgets('refills a name the user cleared', (tester) async {
      await tester.pumpWidget(_editor());

      await _selectProvider(tester, 'Anthropic');
      await tester.enterText(_displayNameField, '');
      await tester.pump();

      await _selectProvider(tester, 'Google (Gemini)');

      expect(_displayNameOf(tester), 'Google (Gemini)');
    });
  });
}

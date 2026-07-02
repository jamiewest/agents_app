// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/strings/configured_agents_strings.dart';
import 'package:agents_app/ui/styles/configured_agents_style.dart';
import 'package:agents_app/ui/views/configured_agents/model_editor.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _openAiSource = ModelSourceConfig(
  id: 'src-openai',
  providerType: ProviderType.openAiCompatible,
  displayName: 'Groq',
  endpoint: 'https://api.groq.com/openai/v1',
);

const _llamaSource = ModelSourceConfig(
  id: 'src-llama',
  providerType: ProviderType.localLlama,
  displayName: 'Local',
);

Widget _editor({
  ModelConfig? initial,
  required List<ModelSourceConfig> sources,
  required void Function(ModelConfig model) onSubmit,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: ModelEditor(
        initial: initial,
        sources: sources,
        style: const ConfiguredAgentsStyle(),
        strings: const ConfiguredAgentsStrings(),
        onSubmit: onSubmit,
        onCancel: () {},
      ),
    ),
  ),
);

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(
      1200,
      2400,
    );
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
    addTearDown(() {
      binding.platformDispatcher.views.first.resetPhysicalSize();
      binding.platformDispatcher.views.first.resetDevicePixelRatio();
    });
  });

  group('ModelEditor OpenAI-compatible profile fields', () {
    testWidgets('shows format, tools, and reasoning controls', (tester) async {
      await tester.pumpWidget(
        _editor(sources: const [_openAiSource], onSubmit: (_) {}),
      );

      expect(find.text('Format'), findsOneWidget);
      expect(find.text('Tool calling'), findsOneWidget);
      expect(find.text('Reasoning tags'), findsOneWidget);
      expect(find.text('Parallel tool calls'), findsOneWidget);
    });

    testWidgets('shows detection for the typed model id', (tester) async {
      await tester.pumpWidget(
        _editor(sources: const [_openAiSource], onSubmit: (_) {}),
      );

      await tester.enterText(
        find.byType(TextFormField).first,
        'llama-3.3-70b-versatile',
      );
      await tester.pump();

      expect(find.text('Auto (detected: llama3)'), findsOneWidget);
    });

    testWidgets('persists profile settings on save', (tester) async {
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(sources: const [_openAiSource], onSubmit: (m) => saved = m),
      );

      await tester.enterText(
        find.byType(TextFormField).first,
        'qwen/qwen3-32b',
      );
      await tester.pump();

      // Pick an explicit format.
      await tester.tap(find.text('Auto (detected: qwen)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mistral').last);
      await tester.pumpAndSettle();

      // Switch tool calling to prompt-injected.
      await tester.tap(find.text('Native (default)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prompt-injected').last);
      await tester.pumpAndSettle();

      // Disable parallel calls.
      await tester.tap(find.byType(Switch));
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.modelId, 'qwen/qwen3-32b');
      expect(saved!.settings[chatFormatSetting], 'mistral');
      expect(saved!.settings[toolsModeSetting], toolsModePrompt);
      expect(saved!.settings[toolsParallelSetting], 'false');
      expect(saved!.settings.containsKey(reasoningTagsSetting), isFalse);
    });

    testWidgets('auto selections persist no profile keys', (tester) async {
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(sources: const [_openAiSource], onSubmit: (m) => saved = m),
      );

      await tester.enterText(
        find.byType(TextFormField).first,
        'llama-3.1-8b-instant',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.settings.containsKey(chatFormatSetting), isFalse);
      expect(saved!.settings.containsKey(toolsModeSetting), isFalse);
      expect(saved!.settings.containsKey(toolsParallelSetting), isFalse);
    });

    testWidgets('loads stored profile settings', (tester) async {
      const initial = ModelConfig(
        id: 'model-1',
        sourceId: 'src-openai',
        modelId: 'qwen/qwen3-32b',
        settings: {
          chatFormatSetting: 'qwen',
          toolsModeSetting: toolsModePrompt,
          toolsParallelSetting: 'false',
        },
      );
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_openAiSource],
          onSubmit: (_) {},
        ),
      );

      expect(find.text('qwen'), findsOneWidget);
      expect(find.text('Prompt-injected'), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.value, isFalse);
    });
  });

  group('ModelEditor local llama format field', () {
    testWidgets('uses a dropdown seeded from stored llama.format', (
      tester,
    ) async {
      const initial = ModelConfig(
        id: 'model-1',
        sourceId: 'src-llama',
        modelId: 'model-1',
        settings: {
          'llama.modelSource': 'url',
          'llama.modelUrl': 'https://example.com/Qwen2.5-7B.Q4.gguf',
          'llama.contextSize': '4096',
          'llama.gpuLayers': '999',
          'llama.format': 'gemma',
        },
      );
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
        ),
      );

      expect(find.text('gemma'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.settings['llama.format'], 'gemma');
      expect(saved!.settings[chatFormatSetting], 'gemma');
    });
  });
}

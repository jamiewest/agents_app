// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:agents_app/features/local_models/local_model_store_io.dart';
import 'package:agents_app/chat_toolkit/strings/configured_agents_strings.dart';
import 'package:agents_app/chat_toolkit/styles/configured_agents_style.dart';
import 'package:agents_app/chat_toolkit/views/configured_agents/model_editor.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';
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
  LlamaModelFilePicker? pickLlamaModelFile,
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
        pickLlamaModelFile: pickLlamaModelFile ?? pickDefaultLlamaModelFile,
        // Hermetic: tests never read real GGUF bytes for the format hint.
        sniffGguf: (source) async => null,
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

  group('ModelEditor local llama thinking capability', () {
    const initial = ModelConfig(
      id: 'model-1',
      sourceId: 'src-llama',
      modelId: 'model-1',
      settings: {
        'llama.modelSource': 'url',
        'llama.modelUrl': 'https://example.com/gemma-4-E2B.gguf',
        'llama.contextSize': '8192',
        'llama.gpuLayers': '999',
        chatFormatSetting: 'gemma',
        ModelCapabilities.visionKey: 'true',
        ModelCapabilities.contextLengthKey: '8192',
        ModelCapabilities.minMemoryMbKey: '8192',
      },
    );

    testWidgets('enabling the switch writes the capability and preserves '
        'preset metadata', (tester) async {
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
        ),
      );

      final thinkingSwitch = tester.widget<Switch>(find.byType(Switch));
      expect(thinkingSwitch.value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.settings[ModelCapabilities.thinkingKey], 'true');
      expect(saved!.capabilities.supportsThinking, isTrue);
      // Settings the form has no field for survive the edit.
      expect(saved!.settings[ModelCapabilities.visionKey], 'true');
      expect(saved!.settings[ModelCapabilities.minMemoryMbKey], '8192');
    });

    testWidgets('a stored capability seeds the switch; turning it off '
        'removes the key', (tester) async {
      final stored = ModelConfig(
        id: initial.id,
        sourceId: initial.sourceId,
        modelId: initial.modelId,
        settings: {...initial.settings, ModelCapabilities.thinkingKey: 'true'},
      );
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: stored,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
        ),
      );

      final thinkingSwitch = tester.widget<Switch>(find.byType(Switch));
      expect(thinkingSwitch.value, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(
        saved!.settings.containsKey(ModelCapabilities.thinkingKey),
        isFalse,
      );
    });

    testWidgets('editing the context size updates the stored context '
        'capability', (tester) async {
      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, '8192'),
        '16384',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(saved!.settings['llama.contextSize'], '16384');
      expect(saved!.settings[ModelCapabilities.contextLengthKey], '16384');
    });
  });

  group('ModelEditor local llama file registration', () {
    const initial = ModelConfig(
      id: 'model-file',
      sourceId: 'src-llama',
      modelId: 'model-file',
      settings: {
        'llama.modelSource': 'file',
        'llama.modelPath': '/original/downloads/gemma.gguf',
        'llama.modelFileName': 'gemma.gguf',
        'llama.contextSize': '8192',
        'llama.gpuLayers': '999',
      },
    );

    tearDown(() => clearSelectedLlamaModelFile('model-file'));

    testWidgets('saving without repicking preserves the restored '
        'registration', (tester) async {
      // Simulates the bootstrap restore: the sandbox-safe app-container
      // copy is the registered selection, while the stored path points at
      // the originally picked (possibly deleted) file.
      registerSelectedLlamaModelFile('model-file', '/app-container/model');

      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
        ),
      );

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(saved, isNotNull);
      expect(
        selectedLlamaModelFilePathFor('model-file'),
        '/app-container/model',
      );
      expect(
        saved!.settings['llama.modelPath'],
        '/original/downloads/gemma.gguf',
      );
    });

    testWidgets('a file picked this session replaces the registration', (
      tester,
    ) async {
      registerSelectedLlamaModelFile('model-file', '/app-container/model');
      final tmp = Directory.systemTemp.createTempSync('model_editor_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      debugLocalModelStoreRoot = Directory('${tmp.path}/store');
      addTearDown(() => debugLocalModelStoreRoot = null);
      final picked = File('${tmp.path}/picked.gguf')..writeAsStringSync('g');

      ModelConfig? saved;
      await tester.pumpWidget(
        _editor(
          initial: initial,
          sources: const [_llamaSource],
          onSubmit: (m) => saved = m,
          pickLlamaModelFile: () async =>
              LlamaModelFileSelection(path: picked.path, name: 'picked.gguf'),
        ),
      );

      await tester.tap(find.text('Choose file').first);
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();

      // The save copies the picked file into the store behind a progress
      // dialog; runAsync lets that real file I/O complete, then a pump
      // processes the dialog dismissing and the submit finishing.
      for (var i = 0; saved == null && i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      expect(saved, isNotNull);
      expect(selectedLlamaModelFilePathFor('model-file'), picked.path);
      expect(saved!.settings['llama.modelPath'], picked.path);
    });
  });

  group('ModelEditor iOS model sourcing', () {
    const preset = ModelConfig(
      id: 'model-preset',
      sourceId: 'src-llama',
      modelId: 'gemma-3-1b',
      displayName: 'Gemma 3 1B',
      settings: {
        'llama.modelUrl':
            'https://huggingface.co/org/repo/resolve/abc123/model.gguf',
        'llama.contextSize': '8192',
      },
    );

    testWidgets('hides URL entry and the source picker', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          _editor(
            initial: preset,
            sources: const [_llamaSource],
            onSubmit: (_) {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('GGUF model URL'), findsNothing);
        expect(find.text('Model source'), findsNothing);
        // The summary still says where the weights came from.
        expect(find.text('model.gguf'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a preset keeps its download URL across a save', (
      tester,
    ) async {
      // The field is hidden, not cleared: dropping the URL here would leave
      // a preset-derived model with nothing to download.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        ModelConfig? saved;
        await tester.pumpWidget(
          _editor(
            initial: preset,
            sources: const [_llamaSource],
            onSubmit: (m) => saved = m,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(
          saved?.settings['llama.modelUrl'],
          'https://huggingface.co/org/repo/resolve/abc123/model.gguf',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('macOS still offers URL entry', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(
          _editor(
            initial: preset,
            sources: const [_llamaSource],
            onSubmit: (_) {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('GGUF model URL'), findsOneWidget);
        expect(find.text('Model source'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

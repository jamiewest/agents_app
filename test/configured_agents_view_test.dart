// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ConfiguredAgentsManager _buildManager() {
  final kv = InMemoryKeyValueStore();
  return ConfiguredAgentsManager(
    sources: ModelSourceStore(kv),
    agents: AgentConfigurationStore(kv),
    secrets: InMemorySecretStore(),
  );
}

Widget _host(
  ConfiguredAgentsManager manager, {
  void Function(SavedAgentConfig)? onAgentSelected,
  ConfiguredAgentsTab initialTab = ConfiguredAgentsTab.sources,
  LlamaModelFilePicker? pickLlamaModelFile,
}) => MaterialApp(
  home: Scaffold(
    body: ConfiguredAgentsView(
      manager: manager,
      onAgentSelected: onAgentSelected,
      initialTab: initialTab,
      pickLlamaModelFile: pickLlamaModelFile,
    ),
  ),
);

Future<ModelSourceConfig> _saveLocalSource(ConfiguredAgentsManager manager) {
  const source = ModelSourceConfig(
    id: 'local-source',
    providerType: ProviderType.localLlama,
    displayName: 'Local models',
  );
  return manager.saveSource(source).then((_) => source);
}

Future<void> _tapAccessSwitch(WidgetTester tester, String label) async {
  final tile = find.ancestor(
    of: find.text(label),
    matching: find.byType(SwitchListTile),
  );
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creates a source through the editor', (tester) async {
    final manager = _buildManager();
    await tester.pumpWidget(_host(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();

    // Fields in order: display name (0), endpoint (1), API key (2).
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'My OpenAI');
    await tester.enterText(fields.at(2), 'sk-123');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('My OpenAI'), findsOneWidget);
    final sources = await manager.sources.listSources();
    expect(sources.single.displayName, 'My OpenAI');
    // The key was routed to the secret store, not the config.
    expect(await manager.getSourceApiKey(sources.single.id), 'sk-123');
  });

  testWidgets('changing the provider dropdown persists', (tester) async {
    final manager = _buildManager();
    await tester.pumpWidget(_host(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();

    // Open the provider dropdown (showing its current value) and pick another.
    await tester.tap(find.text('OpenAI-compatible'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Claude source');
    await tester.enterText(fields.at(2), 'sk-ant');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final source = (await manager.sources.listSources()).single;
    expect(source.providerType, ProviderType.anthropic);
  });

  testWidgets('local llama source and model fields persist', (tester) async {
    final manager = _buildManager();
    await tester.pumpWidget(_host(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI-compatible'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local llama').last);
    await tester.pumpAndSettle();

    expect(find.text('Endpoint (optional)'), findsNothing);
    expect(find.text('API key'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'Local models');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final source = (await manager.sources.listSources()).single;
    expect(source.providerType, ProviderType.localLlama);
    expect(await manager.getSourceApiKey(source.id), isNull);

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();

    expect(find.text('GGUF model URL'), findsOneWidget);
    expect(find.text('Model id'), findsNothing);

    final fields = find.byType(TextFormField);
    await tester.enterText(
      fields.at(0),
      'https://huggingface.co/google/gemma/resolve/main/model.gguf',
    );
    await tester.enterText(fields.at(1), '2048');
    await tester.enterText(fields.at(2), '0');
    await tester.enterText(fields.at(4), 'Gemma local');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final model = (await manager.sources.listModels()).single;
    expect(model.displayName, 'Gemma local');
    expect(model.settings['llama.modelSource'], 'url');
    expect(model.settings['llama.modelUrl'], contains('model.gguf'));
    expect(model.settings.containsKey('llama.modelPath'), isFalse);
    expect(model.settings.containsKey('llama.modelFileName'), isFalse);
    expect(model.settings['llama.contextSize'], '2048');
    expect(model.settings['llama.gpuLayers'], '0');
    expect(model.settings['llama.format'], 'gemma');
  });

  testWidgets('local llama file model fields persist', (tester) async {
    final manager = _buildManager();
    await _saveLocalSource(manager);
    await tester.pumpWidget(
      _host(
        manager,
        initialTab: ConfiguredAgentsTab.models,
        pickLlamaModelFile: () async => const LlamaModelFileSelection(
          path: '/models/gemma-local.gguf',
          name: 'gemma-local.gguf',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File').last);
    await tester.pumpAndSettle();

    expect(find.text('GGUF model file'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Choose file'));
    await tester.pumpAndSettle();
    expect(find.text('gemma-local.gguf'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '2048');
    await tester.enterText(fields.at(1), '0');
    await tester.enterText(fields.at(3), 'Gemma file');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final model = (await manager.sources.listModels()).single;
    expect(model.displayName, 'Gemma file');
    expect(model.settings['llama.modelSource'], 'file');
    expect(model.settings['llama.modelPath'], '/models/gemma-local.gguf');
    expect(model.settings['llama.modelFileName'], 'gemma-local.gguf');
    expect(model.settings.containsKey('llama.modelUrl'), isFalse);
    expect(model.settings['llama.contextSize'], '2048');
    expect(model.settings['llama.gpuLayers'], '0');
    expect(model.settings['llama.format'], 'gemma');
  });

  testWidgets('local llama file mode requires a selected file', (tester) async {
    final manager = _buildManager();
    await _saveLocalSource(manager);
    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.models),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a GGUF model file.'), findsOneWidget);
    expect(await manager.sources.listModels(), isEmpty);
  });

  testWidgets('switching file model back to URL clears file settings', (
    tester,
  ) async {
    final manager = _buildManager();
    final source = await _saveLocalSource(manager);
    await manager.saveModel(
      ModelConfig(
        id: 'file-model',
        sourceId: source.id,
        modelId: 'file-model',
        displayName: 'File model',
        settings: const {
          'llama.modelSource': 'file',
          'llama.modelPath': '/models/old.gguf',
          'llama.modelFileName': 'old.gguf',
          'llama.contextSize': '4096',
          'llama.gpuLayers': '999',
          'llama.format': 'gemma',
        },
      ),
    );
    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.models),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'https://huggingface.co/google/gemma/resolve/main/new.gguf',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final model = (await manager.sources.listModels()).single;
    expect(model.settings['llama.modelSource'], 'url');
    expect(model.settings['llama.modelUrl'], contains('new.gguf'));
    expect(model.settings.containsKey('llama.modelPath'), isFalse);
    expect(model.settings.containsKey('llama.modelFileName'), isFalse);
  });

  testWidgets('blocked source delete offers cascade', (tester) async {
    final manager = _buildManager();
    await manager.saveSource(
      const ModelSourceConfig(
        id: 's1',
        providerType: ProviderType.openAiCompatible,
        displayName: 'Source A',
      ),
      apiKey: 'sk-1',
    );
    await manager.saveModel(
      const ModelConfig(id: 'm1', sourceId: 's1', modelId: 'gpt'),
    );

    await tester.pumpWidget(_host(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    // The block dialog explains why and offers a force-delete.
    expect(find.textContaining('model'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Delete anyway'));
    await tester.pumpAndSettle();

    expect(await manager.sources.listSources(), isEmpty);
    expect(await manager.sources.listModels(), isEmpty);
  });

  testWidgets('selecting an agent fires the callback', (tester) async {
    final manager = _buildManager();
    await manager.saveSource(
      const ModelSourceConfig(
        id: 's1',
        providerType: ProviderType.anthropic,
        displayName: 'Anthropic',
      ),
      apiKey: 'sk-1',
    );
    await manager.saveModel(
      const ModelConfig(id: 'm1', sourceId: 's1', modelId: 'claude'),
    );
    await manager.saveAgent(
      const SavedAgentConfig(id: 'a1', name: 'Helper', modelId: 'm1'),
    );

    SavedAgentConfig? selected;
    await tester.pumpWidget(
      _host(manager, onAgentSelected: (agent) => selected = agent),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Helper'));
    await tester.pumpAndSettle();

    expect(selected?.id, 'a1');
  });

  testWidgets('agent editor persists tool and context access', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final manager = _buildManager();
    await manager.saveSource(
      const ModelSourceConfig(
        id: 's1',
        providerType: ProviderType.anthropic,
        displayName: 'Anthropic',
      ),
      apiKey: 'sk-1',
    );
    await manager.saveModel(
      const ModelConfig(id: 'm1', sourceId: 's1', modelId: 'claude'),
    );

    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.agents),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add agent'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Scoped helper');
    await _tapAccessSwitch(tester, 'Web search');
    await _tapAccessSwitch(tester, 'Location');
    await _tapAccessSwitch(tester, 'Wake lock');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final agent = (await manager.agents.listAgents()).single;
    expect(agent.name, 'Scoped helper');
    expect(agent.access?.enableWebSearch, isFalse);
    expect(agent.access?.enableLocation, isTrue);
    expect(agent.access?.enableWakeLock, isTrue);
    expect(agent.access?.enableFileMemory, isTrue);
  });
}

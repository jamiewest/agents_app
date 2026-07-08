// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:agents_app/data/local_model_store_io.dart';
import 'package:agents_app/ui/views/configured_agents/configured_agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

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

/// Taps Save on a file-mode model and settles through the "saving" dialog.
///
/// The dialog waits on real file I/O (the picked-file copy), which only
/// completes while the real event loop turns — hence the [WidgetTester.runAsync]
/// window between pumps.
Future<void> _saveFileModel(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
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
  // Root the local model store in a temp directory: saving a file-mode model
  // copies the picked file, and the real store would call path_provider,
  // whose platform channel never answers in widget tests.
  late Directory storeRoot;
  setUp(() {
    storeRoot = Directory.systemTemp.createTempSync('configured_agents_test');
    debugLocalModelStoreRoot = storeRoot;
  });
  tearDown(() {
    debugLocalModelStoreRoot = null;
    storeRoot.deleteSync(recursive: true);
  });

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

    // URL-mode text fields in order: model URL (0), projector URL (1),
    // draft URL (2), context size (3), GPU layers (4), display name (5).
    // The format selector is a dropdown, not a text field.
    final fields = find.byType(TextFormField);
    await tester.enterText(
      fields.at(0),
      'https://huggingface.co/google/gemma/resolve/main/model.gguf',
    );
    await tester.enterText(fields.at(3), '2048');
    await tester.enterText(fields.at(4), '0');
    await tester.enterText(fields.at(5), 'Gemma local');
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
    // Empty optional artifact fields persist no keys.
    expect(model.settings.containsKey('llama.mmprojUrl'), isFalse);
    expect(model.settings.containsKey('llama.draftModelUrl'), isFalse);
    expect(model.settings['llama.contextSize'], '2048');
    expect(model.settings['llama.gpuLayers'], '0');
    // The default format selection is Auto, which persists no key; the
    // runtime detects the family from the model URL/file name.
    expect(model.settings.containsKey('llama.format'), isFalse);
  });

  testWidgets('local llama URL-mode projector and draft URLs persist', (
    tester,
  ) async {
    final manager = _buildManager();
    await _saveLocalSource(manager);
    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.models),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(
      fields.at(0),
      'https://huggingface.co/org/repo/resolve/main/model.gguf',
    );
    await tester.enterText(
      fields.at(1),
      'https://huggingface.co/org/repo/resolve/main/mmproj.gguf',
    );
    await tester.enterText(
      fields.at(2),
      'https://huggingface.co/org/repo/resolve/main/draft.gguf',
    );
    await tester.enterText(fields.at(5), 'Vision local');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final model = (await manager.sources.listModels()).single;
    expect(model.settings['llama.mmprojUrl'], contains('mmproj.gguf'));
    expect(model.settings['llama.draftModelUrl'], contains('draft.gguf'));
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
    await tester.tap(find.widgetWithText(OutlinedButton, 'Choose file').first);
    await tester.pumpAndSettle();
    expect(find.text('gemma-local.gguf'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '2048');
    await tester.enterText(fields.at(1), '0');
    await tester.enterText(fields.at(2), 'Gemma file');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await _saveFileModel(tester);

    final model = (await manager.sources.listModels()).single;
    expect(model.displayName, 'Gemma file');
    expect(model.settings['llama.modelSource'], 'file');
    expect(model.settings['llama.modelPath'], '/models/gemma-local.gguf');
    expect(model.settings['llama.modelFileName'], 'gemma-local.gguf');
    expect(model.settings.containsKey('llama.modelUrl'), isFalse);
    expect(model.settings['llama.contextSize'], '2048');
    expect(model.settings['llama.gpuLayers'], '0');
    // Auto format persists no key; runtime detection reads the file name.
    expect(model.settings.containsKey('llama.format'), isFalse);
  });

  testWidgets('local llama file-mode projector and draft selections persist', (
    tester,
  ) async {
    final manager = _buildManager();
    await _saveLocalSource(manager);
    const selections = [
      LlamaModelFileSelection(path: '/models/main.gguf', name: 'main.gguf'),
      LlamaModelFileSelection(path: '/models/mmproj.gguf', name: 'mmproj.gguf'),
      LlamaModelFileSelection(path: '/models/draft.gguf', name: 'draft.gguf'),
    ];
    var pickCount = 0;
    await tester.pumpWidget(
      _host(
        manager,
        initialTab: ConfiguredAgentsTab.models,
        pickLlamaModelFile: () async => selections[pickCount++],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File').last);
    await tester.pumpAndSettle();

    // Choose file buttons in order: main model, projector, draft.
    final chooseButtons = find.widgetWithText(OutlinedButton, 'Choose file');
    for (var i = 0; i < 3; i++) {
      await tester.ensureVisible(chooseButtons.at(i));
      await tester.pumpAndSettle();
      await tester.tap(chooseButtons.at(i));
      await tester.pumpAndSettle();
    }
    expect(find.text('mmproj.gguf'), findsOneWidget);
    expect(find.text('draft.gguf'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await _saveFileModel(tester);

    final model = (await manager.sources.listModels()).single;
    expect(model.settings['llama.modelSource'], 'file');
    expect(model.settings['llama.mmprojPath'], '/models/mmproj.gguf');
    expect(model.settings['llama.mmprojFileName'], 'mmproj.gguf');
    expect(model.settings['llama.draftModelPath'], '/models/draft.gguf');
    expect(model.settings['llama.draftModelFileName'], 'draft.gguf');
    expect(
      selectedLlamaModelFilePathFor(model.id, kind: LlamaArtifactKind.mmproj),
      '/models/mmproj.gguf',
    );
    expect(
      selectedLlamaModelFilePathFor(model.id, kind: LlamaArtifactKind.draft),
      '/models/draft.gguf',
    );
    clearSelectedLlamaModelFile(model.id);
  });

  testWidgets('clearing an optional file artifact drops its settings', (
    tester,
  ) async {
    final manager = _buildManager();
    await _saveLocalSource(manager);
    const selections = [
      LlamaModelFileSelection(path: '/models/main.gguf', name: 'main.gguf'),
      LlamaModelFileSelection(path: '/models/draft.gguf', name: 'draft.gguf'),
    ];
    var pickCount = 0;
    await tester.pumpWidget(
      _host(
        manager,
        initialTab: ConfiguredAgentsTab.models,
        pickLlamaModelFile: () async => selections[pickCount++],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File').last);
    await tester.pumpAndSettle();

    final chooseButtons = find.widgetWithText(OutlinedButton, 'Choose file');
    await tester.tap(chooseButtons.at(0));
    await tester.pumpAndSettle();
    await tester.ensureVisible(chooseButtons.at(2));
    await tester.pumpAndSettle();
    await tester.tap(chooseButtons.at(2));
    await tester.pumpAndSettle();
    expect(find.text('draft.gguf'), findsOneWidget);

    await tester.tap(find.byIcon(Symbols.close));
    await tester.pumpAndSettle();
    expect(find.text('draft.gguf'), findsNothing);

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await _saveFileModel(tester);

    final model = (await manager.sources.listModels()).single;
    expect(model.settings['llama.modelFileName'], 'main.gguf');
    expect(model.settings.containsKey('llama.draftModelPath'), isFalse);
    expect(model.settings.containsKey('llama.draftModelFileName'), isFalse);
    expect(
      selectedLlamaModelFilePathFor(model.id, kind: LlamaArtifactKind.draft),
      isNull,
    );
    clearSelectedLlamaModelFile(model.id);
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
    // Three file fields make the form taller than the default 800x600 test
    // surface; the mode dropdown's menu would open partially offscreen.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
          'llama.mmprojPath': '/models/old-mmproj.gguf',
          'llama.mmprojFileName': 'old-mmproj.gguf',
          'llama.draftModelPath': '/models/old-draft.gguf',
          'llama.draftModelFileName': 'old-draft.gguf',
          'llama.contextSize': '4096',
          'llama.gpuLayers': '999',
          'llama.format': 'gemma',
        },
      ),
    );
    registerSelectedLlamaModelFile(
      'file-model',
      '/models/old-mmproj.gguf',
      kind: LlamaArtifactKind.mmproj,
    );
    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.models),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Symbols.edit));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('URL').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextFormField).at(0));
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
    expect(model.settings.containsKey('llama.mmprojPath'), isFalse);
    expect(model.settings.containsKey('llama.mmprojFileName'), isFalse);
    expect(model.settings.containsKey('llama.draftModelPath'), isFalse);
    expect(model.settings.containsKey('llama.draftModelFileName'), isFalse);
    expect(
      selectedLlamaModelFilePathFor(
        'file-model',
        kind: LlamaArtifactKind.mmproj,
      ),
      isNull,
    );
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

    await tester.tap(find.byIcon(Symbols.delete).first);
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

  testWidgets('agent editor persists a delegate with guidance', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
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
    await manager.saveAgent(
      const SavedAgentConfig(id: 'a2', name: 'Accounting', modelId: 'm1'),
    );

    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.agents),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add agent'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Helper');
    await _tapAccessSwitch(tester, 'Accounting');

    final guidanceField = find.byType(TextFormField).last;
    await tester.ensureVisible(guidanceField);
    await tester.pumpAndSettle();
    await tester.enterText(guidanceField, 'Use for cost schedules.');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final agents = await manager.agents.listAgents();
    final helper = agents.singleWhere((agent) => agent.name == 'Helper');
    expect(helper.delegations, hasLength(1));
    expect(helper.delegations.single.agentId, 'a2');
    expect(helper.delegations.single.instructions, 'Use for cost schedules.');
  });

  testWidgets('agent editor omits itself from delegate candidates', (
    tester,
  ) async {
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
    await manager.saveAgent(
      const SavedAgentConfig(id: 'a1', name: 'Helper', modelId: 'm1'),
    );
    await manager.saveAgent(
      const SavedAgentConfig(id: 'a2', name: 'Accounting', modelId: 'm1'),
    );

    await tester.pumpWidget(
      _host(manager, initialTab: ConfiguredAgentsTab.agents),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Symbols.edit).first);
    await tester.pumpAndSettle();

    // The list behind the dialog uses plain ListTiles, so SwitchListTile
    // ancestors identify the delegate candidates inside the editor.
    expect(
      find.ancestor(
        of: find.text('Accounting'),
        matching: find.byType(SwitchListTile),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Helper'),
        matching: find.byType(SwitchListTile),
      ),
      findsNothing,
    );
  });
}

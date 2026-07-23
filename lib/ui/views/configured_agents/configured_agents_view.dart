// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../dialogs/adaptive_snack_bar/adaptive_snack_bar.dart';
import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';
import 'agent_editor.dart';
import 'configured_agents_controller.dart';
import 'model_editor.dart';
import 'source_editor.dart';

/// Builds a custom tile for a list item of type [T].
typedef ConfiguredAgentsTileBuilder<T> =
    Widget Function(BuildContext context, T item);

/// Confirms a destructive action, returning whether to proceed.
typedef ConfirmDelete =
    Future<bool> Function(BuildContext context, String itemLabel);

/// Which tab the manager opens on.
enum ConfiguredAgentsTab {
  /// The sources tab.
  sources,

  /// The models tab.
  models,

  /// The agents tab.
  agents,
}

/// A complete settings surface for runtime-configurable agents.
///
/// Presents sources, models, and agents in three tabs with create/edit/delete
/// flows, validation, and referential-integrity handling delegated to the
/// [ConfiguredAgentsManager]. Smaller widgets (`SourceEditor`, `ModelEditor`,
/// `AgentEditor`, `ConfiguredAgentPicker`) are public so apps can embed just the
/// pieces they need.
///
/// Expects to be placed where it receives bounded constraints (for example, a
/// [Scaffold] body) and where [Navigator] and [ScaffoldMessenger] ancestors are
/// available for dialogs and snack bars.
class ConfiguredAgentsView extends StatefulWidget {
  /// Creates a [ConfiguredAgentsView].
  const ConfiguredAgentsView({
    required this.manager,
    this.onAgentSelected,
    this.style,
    this.strings,
    this.initialTab = ConfiguredAgentsTab.sources,
    this.sourceTileBuilder,
    this.modelTileBuilder,
    this.agentTileBuilder,
    this.confirmDelete,
    this.pickLlamaModelFile,
    super.key,
  });

  /// Coordinates persistence and integrity for the displayed configuration.
  final ConfiguredAgentsManager manager;

  /// Invoked when the user selects a saved agent to use.
  final void Function(SavedAgentConfig agent)? onAgentSelected;

  /// Optional style override.
  final ConfiguredAgentsStyle? style;

  /// Optional strings override.
  final ConfiguredAgentsStrings? strings;

  /// The tab shown initially.
  final ConfiguredAgentsTab initialTab;

  /// Optional custom tile for a source.
  final ConfiguredAgentsTileBuilder<ModelSourceConfig>? sourceTileBuilder;

  /// Optional custom tile for a model.
  final ConfiguredAgentsTileBuilder<ModelConfig>? modelTileBuilder;

  /// Optional custom tile for an agent.
  final ConfiguredAgentsTileBuilder<SavedAgentConfig>? agentTileBuilder;

  /// Optional custom delete confirmation. Defaults to an adaptive dialog.
  final ConfirmDelete? confirmDelete;

  /// Optional local llama file picker override.
  final LlamaModelFilePicker? pickLlamaModelFile;

  @override
  State<ConfiguredAgentsView> createState() => _ConfiguredAgentsViewState();
}

class _ConfiguredAgentsViewState extends State<ConfiguredAgentsView> {
  late final ConfiguredAgentsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConfiguredAgentsController(widget.manager);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final strings = _resolveStrings(_resolveStyle());
    AdaptiveSnackBar.show(
      context,
      message,
      copyText: message,
      copyLabel: strings.copy,
    );
  }

  ConfiguredAgentsStyle _resolveStyle() =>
      ConfiguredAgentsStyle.resolveFor(context, widget.style);

  ConfiguredAgentsStrings _resolveStrings(ConfiguredAgentsStyle style) =>
      widget.strings ?? style.strings ?? ConfiguredAgentsStrings.defaults;

  @override
  Widget build(BuildContext context) {
    final style = _resolveStyle();
    final strings = _resolveStrings(style);

    return DefaultTabController(
      length: 3,
      initialIndex: ConfiguredAgentsTab.values.indexOf(widget.initialTab),
      child: Material(
        color: style.backgroundColor ?? Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: strings.sourcesTab),
                Tab(text: strings.modelsTab),
                Tab(text: strings.agentsTab),
              ],
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  if (_controller.loading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return TabBarView(
                    children: [
                      _buildSourcesTab(style, strings),
                      _buildModelsTab(style, strings),
                      _buildAgentsTab(style, strings),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Sources -------------------------------------------------------------

  Widget _buildSourcesTab(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
  ) => _TabScaffold(
    addLabel: strings.addSource,
    onAdd: () => _editSource(style, strings, null),
    style: style,
    child: _controller.sources.isEmpty
        ? _EmptyState(message: strings.noSources, style: style)
        : ListView(
            children: [
              for (final source in _controller.sources)
                widget.sourceTileBuilder?.call(context, source) ??
                    _sourceTile(style, strings, source),
            ],
          ),
  );

  Widget _sourceTile(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    ModelSourceConfig source,
  ) {
    final provider = source.providerType.wireName;
    return ListTile(
      contentPadding: style.tilePadding,
      title: Text(source.displayName, style: style.titleTextStyle),
      subtitle: Text(
        source.endpoint == null ? provider : '$provider · ${source.endpoint}',
        style: style.subtitleTextStyle,
      ),
      trailing: _tileActions(
        onEdit: () => _editSource(style, strings, source),
        onDelete: () => _deleteSource(strings, source),
        strings: strings,
      ),
    );
  }

  Future<void> _editSource(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    ModelSourceConfig? source,
  ) async {
    final hasKey = source == null
        ? false
        : await _controller.hasApiKey(source.id);
    if (!mounted) return;
    await _showEditorDialog(
      title: source == null ? strings.addSource : strings.editSource,
      builder: (close) => SourceEditor(
        initial: source,
        hasStoredKey: hasKey,
        style: style,
        strings: strings,
        onCancel: close,
        onSubmit: (edited, apiKey) async {
          final error = await _controller.saveSource(edited, apiKey: apiKey);
          close();
          if (error != null) _showMessage(error);
        },
      ),
    );
  }

  Future<void> _deleteSource(
    ConfiguredAgentsStrings strings,
    ModelSourceConfig source,
  ) async {
    if (!await _confirm(strings, source.displayName)) return;
    final error = await _controller.deleteSource(source.id);
    if (error != null && mounted) {
      await _offerCascade(
        strings,
        error,
        () => _controller.deleteSource(source.id, cascade: true),
      );
    }
  }

  // --- Models --------------------------------------------------------------

  Widget _buildModelsTab(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
  ) => _TabScaffold(
    addLabel: strings.addModel,
    onAdd: _controller.sources.isEmpty
        ? null
        : () => _editModel(style, strings, null),
    style: style,
    child: _controller.models.isEmpty
        ? _EmptyState(message: strings.noModels, style: style)
        : ListView(
            children: [
              for (final model in _controller.models)
                widget.modelTileBuilder?.call(context, model) ??
                    _modelTile(style, strings, model),
            ],
          ),
  );

  Widget _modelTile(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    ModelConfig model,
  ) {
    final source = _controller.sources
        .where((s) => s.id == model.sourceId)
        .firstOrNull;
    return ListTile(
      contentPadding: style.tilePadding,
      title: Text(model.label, style: style.titleTextStyle),
      subtitle: Text(
        source?.displayName ?? model.modelId,
        style: style.subtitleTextStyle,
      ),
      trailing: _tileActions(
        onEdit: () => _editModel(style, strings, model),
        onDelete: () => _deleteModel(strings, model),
        strings: strings,
      ),
    );
  }

  Future<void> _editModel(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    ModelConfig? model,
  ) async {
    await _showEditorDialog(
      title: model == null ? strings.addModel : strings.editModel,
      builder: (close) => ModelEditor(
        initial: model,
        sources: _controller.sources,
        style: style,
        strings: strings,
        pickLlamaModelFile:
            widget.pickLlamaModelFile ?? pickDefaultLlamaModelFile,
        onCancel: close,
        onSubmit: (edited) async {
          final error = await _controller.saveModel(edited);
          close();
          if (error != null) _showMessage(error);
        },
      ),
    );
  }

  Future<void> _deleteModel(
    ConfiguredAgentsStrings strings,
    ModelConfig model,
  ) async {
    if (!await _confirm(strings, model.label)) return;
    final error = await _controller.deleteModel(model.id);
    if (error != null && mounted) {
      await _offerCascade(
        strings,
        error,
        () => _controller.deleteModel(model.id, cascade: true),
      );
    }
  }

  // --- Agents --------------------------------------------------------------

  Widget _buildAgentsTab(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
  ) => _TabScaffold(
    addLabel: strings.addAgent,
    onAdd: _controller.models.isEmpty
        ? null
        : () => _editAgent(style, strings, null),
    style: style,
    child: _controller.agents.isEmpty
        ? _EmptyState(
            message: _controller.models.isEmpty
                ? strings.selectModelFirst
                : strings.noAgents,
            style: style,
          )
        : ListView(
            children: [
              for (final agent in _controller.agents)
                widget.agentTileBuilder?.call(context, agent) ??
                    _agentTile(style, strings, agent),
            ],
          ),
  );

  Widget _agentTile(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    SavedAgentConfig agent,
  ) => ListTile(
    contentPadding: style.tilePadding,
    title: Text(agent.name, style: style.titleTextStyle),
    subtitle: agent.description.isEmpty
        ? null
        : Text(agent.description, style: style.subtitleTextStyle),
    onTap: widget.onAgentSelected == null
        ? null
        : () => widget.onAgentSelected!(agent),
    trailing: _tileActions(
      onEdit: () => _editAgent(style, strings, agent),
      onDelete: () => _deleteAgent(strings, agent),
      strings: strings,
    ),
  );

  Future<void> _editAgent(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
    SavedAgentConfig? agent,
  ) async {
    await _showEditorDialog(
      title: agent == null ? strings.addAgent : strings.editAgent,
      builder: (close) => AgentEditor(
        initial: agent,
        models: _controller.models,
        agents: _controller.agents,
        networkModelIds: {
          for (final model in _controller.models)
            if (_controller.sources.any(
              (source) =>
                  source.id == model.sourceId &&
                  source.providerType == ProviderType.network,
            ))
              model.id,
        },
        style: style,
        strings: strings,
        onCancel: close,
        onSubmit: (edited) async {
          final error = await _controller.saveAgent(edited);
          close();
          if (error != null) _showMessage(error);
        },
      ),
    );
  }

  Future<void> _deleteAgent(
    ConfiguredAgentsStrings strings,
    SavedAgentConfig agent,
  ) async {
    if (!await _confirm(strings, agent.name)) return;
    final error = await _controller.deleteAgent(agent.id);
    if (error != null && mounted) {
      await _offerCascade(
        strings,
        error,
        () => _controller.deleteAgent(agent.id, cascade: true),
      );
    }
  }

  // --- Shared helpers ------------------------------------------------------

  Widget _tileActions({
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    required ConfiguredAgentsStrings strings,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: strings.edit,
        icon: const Icon(LucideIcons.pencil300),
        onPressed: onEdit,
      ),
      IconButton(
        tooltip: strings.delete,
        icon: const Icon(LucideIcons.trash2300),
        onPressed: onDelete,
      ),
    ],
  );

  Future<void> _showEditorDialog({
    required String title,
    required Widget Function(VoidCallback close) builder,
  }) => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      void close() => Navigator.of(dialogContext).pop();
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(child: builder(close)),
        ),
      );
    },
  );

  Future<bool> _confirm(
    ConfiguredAgentsStrings strings,
    String itemLabel,
  ) async {
    if (widget.confirmDelete != null) {
      return widget.confirmDelete!(context, itemLabel);
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDeleteTitle),
        content: Text('${strings.confirmDeleteMessage}\n\n$itemLabel'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _offerCascade(
    ConfiguredAgentsStrings strings,
    String blockMessage,
    Future<String?> Function() cascade,
  ) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDeleteTitle),
        content: Text(blockMessage),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: blockMessage)),
            child: Text(strings.copy),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.cascadeDelete),
          ),
        ],
      ),
    );
    if (proceed ?? false) {
      final error = await cascade();
      if (error != null) _showMessage(error);
    }
  }
}

class _TabScaffold extends StatelessWidget {
  const _TabScaffold({
    required this.addLabel,
    required this.onAdd,
    required this.style,
    required this.child,
  });

  final String addLabel;
  final VoidCallback? onAdd;
  final ConfiguredAgentsStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onAdd,
            style: style.accentColor == null
                ? null
                : FilledButton.styleFrom(backgroundColor: style.accentColor),
            icon: const Icon(LucideIcons.plus300),
            label: Text(addLabel),
          ),
        ),
      ),
      Expanded(child: child),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.style});

  final String message;
  final ConfiguredAgentsStyle style;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: style.contentPadding ?? const EdgeInsets.all(16),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: style.bodyTextStyle,
      ),
    ),
  );
}

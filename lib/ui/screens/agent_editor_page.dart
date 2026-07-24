// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../strings/configured_agents_strings.dart';
import '../styles/configured_agents_style.dart';
import '../views/configured_agents/configured_agents.dart';
import 'agent_center_nav.dart';

/// A pushed page that creates or edits one agent, model, or source.
///
/// Every editor is now a full page — the old width-conditional inline pane is
/// gone — so unsaved edits are guarded by one uniform [PopScope]. On save the
/// page pops back to the catalog; the catalog reloads off
/// `configurationChanges`, so the new item is there when you land.
class AgentEditorPage extends StatefulWidget {
  /// Creates an [AgentEditorPage].
  const AgentEditorPage({
    required this.services,
    required this.kind,
    this.editingId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// Which kind of item to edit. Must not be [AgentCenterTab.overview].
  final AgentCenterTab kind;

  /// The item being edited, or null to create.
  final String? editingId;

  @override
  State<AgentEditorPage> createState() => _AgentEditorPageState();
}

class _AgentEditorPageState extends State<AgentEditorPage> {
  late final ConfiguredAgentsController _controller;
  bool _dirty = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = ConfiguredAgentsController(
      widget.services.getRequiredService<ConfiguredAgentsManager>(),
    );
    unawaited(
      _controller.load().then((_) {
        if (mounted) setState(() => _loaded = true);
      }),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ConfiguredAgentsStyle get _style =>
      ConfiguredAgentsStyle.resolveFor(context, null);
  ConfiguredAgentsStrings get _strings =>
      _style.strings ?? ConfiguredAgentsStrings.defaults;

  bool get _creating => widget.editingId == null;

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  Future<void> _finish(String? error) async {
    _dirty = false;
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('This form has edits that have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      // Capture the navigator before the await so no context crosses the gap.
      final navigator = Navigator.of(context);
      if (await _confirmDiscard() && mounted) navigator.pop();
    },
    child: Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _loaded
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  // A card surface so the form reads in the same visual
                  // language as the dashboard and the catalog cards.
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _editor(),
                    ),
                  ),
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    ),
  );

  Widget _editor() {
    final style = _style;
    final strings = _strings;
    void cancel() => Navigator.of(context).pop();

    switch (widget.kind) {
      case AgentCenterTab.agents:
        return AgentEditor(
          initial: _find(_controller.agents, (a) => a.id),
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
          onDirty: _markDirty,
          onCancel: cancel,
          onSubmit: (edited) async =>
              _finish(await _controller.saveAgent(edited)),
        );
      case AgentCenterTab.models:
        return ModelEditor(
          initial: _find(_controller.models, (m) => m.id),
          sources: _controller.sources,
          style: style,
          strings: strings,
          pickLlamaModelFile: pickDefaultLlamaModelFile,
          onDirty: _markDirty,
          onCancel: cancel,
          onSubmit: (edited) async =>
              _finish(await _controller.saveModel(edited)),
        );
      case AgentCenterTab.sources:
        return _SourceEditorHost(
          controller: _controller,
          source: _find(_controller.sources, (s) => s.id),
          style: style,
          strings: strings,
          onDirty: _markDirty,
          onCancel: cancel,
          onSaved: _finish,
        );
      case AgentCenterTab.overview:
        return const SizedBox.shrink();
    }
  }

  T? _find<T>(List<T> items, String Function(T) id) {
    final target = widget.editingId;
    if (target == null) return null;
    for (final item in items) {
      if (id(item) == target) return item;
    }
    return null;
  }

  String get _title => switch ((widget.kind, _creating)) {
    (AgentCenterTab.agents, true) => _strings.addAgent,
    (AgentCenterTab.agents, false) => _strings.editAgent,
    (AgentCenterTab.models, true) => _strings.addModel,
    (AgentCenterTab.models, false) => _strings.editModel,
    (AgentCenterTab.sources, true) => _strings.addSource,
    (AgentCenterTab.sources, false) => _strings.editSource,
    (AgentCenterTab.overview, _) => '',
  };
}

/// Hosts [SourceEditor], which needs to know whether a key is already stored
/// before it can render, and carries the web key-storage caveat.
class _SourceEditorHost extends StatefulWidget {
  const _SourceEditorHost({
    required this.controller,
    required this.source,
    required this.style,
    required this.strings,
    required this.onDirty,
    required this.onCancel,
    required this.onSaved,
  });

  final ConfiguredAgentsController controller;
  final ModelSourceConfig? source;
  final ConfiguredAgentsStyle style;
  final ConfiguredAgentsStrings strings;
  final VoidCallback onDirty;
  final VoidCallback onCancel;
  final Future<void> Function(String? error) onSaved;

  @override
  State<_SourceEditorHost> createState() => _SourceEditorHostState();
}

class _SourceEditorHostState extends State<_SourceEditorHost> {
  late Future<bool> _hasKey;

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    _hasKey = source == null
        ? Future.value(false)
        : widget.controller.hasApiKey(source.id);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _hasKey,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WebKeyStorageNotice(),
          SourceEditor(
            initial: widget.source,
            hasStoredKey: snapshot.data!,
            style: widget.style,
            strings: widget.strings,
            onDirty: widget.onDirty,
            onCancel: widget.onCancel,
            onSubmit: (edited, apiKey) async => widget.onSaved(
              await widget.controller.saveSource(edited, apiKey: apiKey),
            ),
          ),
        ],
      );
    },
  );
}

/// Explains where API keys live, and that the web fallback is weaker.
class WebKeyStorageNotice extends StatelessWidget {
  /// Creates a [WebKeyStorageNotice].
  const WebKeyStorageNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.lock300, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Keys are stored in secure storage. On the web this falls '
              'back to browser storage — production apps should proxy '
              'provider requests through a backend.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

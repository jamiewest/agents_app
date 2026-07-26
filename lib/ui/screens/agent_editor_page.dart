// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../dialogs/discard_changes.dart';
import '../strings/configured_agents_strings.dart';
import '../styles/configured_agents_style.dart';
import '../views/configured_agents/configured_agents.dart';
import 'agent_center_nav.dart';

/// The title an editor for [kind] carries, creating or editing.
///
/// Shared so the pushed page's app bar and the two-pane detail header name
/// the same form the same way.
String agentEditorTitle(
  AgentCenterTab kind, {
  required bool creating,
  ConfiguredAgentsStrings? strings,
}) {
  final s = strings ?? ConfiguredAgentsStrings.defaults;
  return switch ((kind, creating)) {
    (AgentCenterTab.agents, true) => s.addAgent,
    (AgentCenterTab.agents, false) => s.editAgent,
    (AgentCenterTab.models, true) => s.addModel,
    (AgentCenterTab.models, false) => s.editModel,
    (AgentCenterTab.sources, true) => s.addSource,
    (AgentCenterTab.sources, false) => s.editSource,
    (AgentCenterTab.overview, _) => '',
  };
}

/// A pushed page that creates or edits one agent, model, or source.
///
/// The page owns only the chrome — an app bar and the unsaved-edits guard on
/// back — while [AgentEditorBody] owns the form. Wide layouts skip this page
/// and host the same body in the catalog's detail pane. On save the page pops
/// back to the catalog; the catalog reloads off `configurationChanges`, so
/// the new item is there when you land.
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
  bool _dirty = false;

  void _markDirty() {
    // The editors only report dirty after their first frame, so this is a
    // genuine user edit and never fires during build.
    if (_dirty || !mounted) return;
    setState(() => _dirty = true);
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      // Capture the navigator before the await so no context crosses the gap.
      final navigator = Navigator.of(context);
      if (await confirmDiscardChanges(context) && mounted) navigator.pop();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          agentEditorTitle(
            widget.kind,
            creating: widget.editingId == null,
            strings: ConfiguredAgentsStyle.resolveFor(context, null).strings,
          ),
        ),
      ),
      body: AgentEditorBody(
        services: widget.services,
        kind: widget.kind,
        editingId: widget.editingId,
        onDirty: _markDirty,
        onCancel: () => Navigator.of(context).pop(),
        onSaved: _finish,
      ),
    ),
  );
}

/// The form half of an editor, without page chrome.
///
/// Hosted by [AgentEditorPage] on narrow layouts and directly by the catalog's
/// detail pane on wide ones. Reports the first edit through [onDirty] so the
/// host can guard whatever would take the form away — a back gesture on a
/// page, a change of selection in a pane.
class AgentEditorBody extends StatefulWidget {
  /// Creates an [AgentEditorBody].
  const AgentEditorBody({
    required this.services,
    required this.kind,
    required this.onDirty,
    required this.onCancel,
    required this.onSaved,
    this.editingId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// Which kind of item to edit. Must not be [AgentCenterTab.overview].
  final AgentCenterTab kind;

  /// The item being edited, or null to create.
  final String? editingId;

  /// Invoked on the first genuine edit.
  final VoidCallback onDirty;

  /// Invoked when the user abandons the form.
  final VoidCallback onCancel;

  /// Invoked after a save attempt with its error, or null on success.
  final Future<void> Function(String? error) onSaved;

  @override
  State<AgentEditorBody> createState() => _AgentEditorBodyState();
}

class _AgentEditorBodyState extends State<AgentEditorBody> {
  late final ConfiguredAgentsController _controller;
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

  @override
  Widget build(BuildContext context) => _loaded
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
      : const Center(child: CircularProgressIndicator());

  Widget _editor() {
    final style = _style;
    final strings = _strings;

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
          onDirty: widget.onDirty,
          onCancel: widget.onCancel,
          onSubmit: (edited) async =>
              widget.onSaved(await _controller.saveAgent(edited)),
        );
      case AgentCenterTab.models:
        return ModelEditor(
          initial: _find(_controller.models, (m) => m.id),
          sources: _controller.sources,
          style: style,
          strings: strings,
          pickLlamaModelFile: pickDefaultLlamaModelFile,
          onDirty: widget.onDirty,
          onCancel: widget.onCancel,
          onSubmit: (edited) async =>
              widget.onSaved(await _controller.saveModel(edited)),
        );
      case AgentCenterTab.sources:
        return _SourceEditorHost(
          controller: _controller,
          source: _find(_controller.sources, (s) => s.id),
          style: style,
          strings: strings,
          onDirty: widget.onDirty,
          onCancel: widget.onCancel,
          onSaved: widget.onSaved,
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

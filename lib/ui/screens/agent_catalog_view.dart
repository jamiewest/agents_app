// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../chat_toolkit/dialogs/adaptive_snack_bar/adaptive_snack_bar.dart';
import '../dialogs/discard_changes.dart';
import '../../chat_toolkit/strings/configured_agents_strings.dart';
import '../../chat_toolkit/views/configured_agents/configured_agents.dart';
import '../widgets/agent_dashboard.dart' show compactTokens;
import '../widgets/draggable_separator.dart';
import '../widgets/empty_state.dart';
import 'agent_center_nav.dart';
import 'agent_detail_screen.dart';
import 'agent_editor_page.dart';

/// Width at which a catalog stops pushing a page for the item you pick and
/// shows it beside the list instead.
///
/// Measured against the catalog's own constraints, not the window: the outer
/// rail and the Agent Center's nav panel — which the user can drag within the
/// shared side-panel bounds — are already spent by the time this view is laid
/// out. So a window wide enough for the split at one panel width may not be
/// at another.
const double catalogTwoPaneBreakpoint = 880;

/// One of the three catalog pages of the Agent Center.
///
/// Renders a searchable list of cards for [kind] (agents, models, or
/// sources) and hosts create/delete. Wide layouts put what you pick in a
/// detail pane beside the list — a stretched window has room for both, and
/// paging away from the list to change one field is pure friction. Narrow
/// layouts keep the pushed routes, which also serve deep links at any width.
/// The cards echo the Overview's card language — a title, a supporting line,
/// and a small metric row — so the catalogs no longer look unlike the
/// dashboard.
class AgentCatalogView extends StatefulWidget {
  /// Creates an [AgentCatalogView].
  const AgentCatalogView({
    required this.services,
    required this.kind,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// Which catalog to show. Must not be [AgentCenterTab.overview].
  final AgentCenterTab kind;

  @override
  State<AgentCatalogView> createState() => _AgentCatalogViewState();
}

/// Lists shorter than this are faster to scan than to search.
const int _searchThreshold = 6;

/// What the detail pane shows.
///
/// Agents have a read-only detail page, so they get a viewing state as well;
/// models and sources go straight to their form.
@immutable
class _Detail {
  const _Detail.creating() : id = null, editing = true;
  const _Detail.viewing(String this.id) : editing = false;
  const _Detail.editing(String this.id) : editing = true;

  /// The item shown, or null when creating a new one.
  final String? id;

  /// Whether the pane holds an editable form rather than a read-only view.
  final bool editing;
}

class _AgentCatalogViewState extends State<AgentCatalogView> {
  late final ConfiguredAgentsController _controller;
  late final AgentRunTelemetryStore _runs;
  late final UsageStore _usage;
  StreamSubscription<void>? _configSub;
  StreamSubscription<List<AgentRunRecord>>? _runsSub;

  /// Per-agent run summaries, keyed by agent id.
  Map<String, _AgentStats> _stats = const {};

  final _searchController = TextEditingController();
  String _search = '';

  /// What the detail pane shows, on layouts wide enough to have one.
  _Detail? _detail;

  /// Whether the form in the detail pane has edits worth guarding.
  bool _editorDirty = false;

  double _listWidth = 340;

  @override
  void initState() {
    super.initState();
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    _controller = ConfiguredAgentsController(manager);
    _runs = widget.services.getRequiredService<AgentRunTelemetryStore>();
    _usage = widget.services.getRequiredService<UsageStore>();
    unawaited(_load());
    _configSub = manager.configurationChanges.listen((_) => unawaited(_load()));
    _runsSub = _runs.watch().listen((_) => unawaited(_loadStats()));
  }

  @override
  void dispose() {
    unawaited(_configSub?.cancel());
    unawaited(_runsSub?.cancel());
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _controller.load();
    // Deleting the item in the pane leaves it pointing at nothing. Dropping
    // it here rather than during build keeps the reload as the one thing that
    // schedules the frame; the dirty flag goes with it, or the next selection
    // would prompt about a form that no longer exists.
    final id = _detail?.id;
    if (mounted && id != null && _isStale(id)) {
      setState(() {
        _detail = null;
        _editorDirty = false;
      });
    }
    await _loadStats();
  }

  /// Loads per-agent run counts, success rate, and tokens — the metric the
  /// agent cards show. Cheap: one pass over the run ledger and the per-agent
  /// token rollup.
  Future<void> _loadStats() async {
    if (widget.kind != AgentCenterTab.agents) return;
    final runs = await _runs.list();
    final tokens = await _usage.totalsByAgent();
    final byAgent = <String, _AgentStats>{};
    for (final run in runs) {
      final stat = byAgent.putIfAbsent(run.agentId, () => _AgentStats());
      switch (run.status) {
        case AgentRunStatus.succeeded:
          stat.succeeded++;
        case AgentRunStatus.failed:
          stat.failed++;
        case AgentRunStatus.running:
        case AgentRunStatus.interrupted:
          break;
      }
    }
    for (final entry in tokens.entries) {
      byAgent.putIfAbsent(entry.key, () => _AgentStats()).tokens =
          entry.value.totalTokens;
    }
    if (mounted) setState(() => _stats = byAgent);
  }

  ConfiguredAgentsStrings get _strings => ConfiguredAgentsStrings.defaults;

  void _showMessage(String message) {
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message,
      copyText: message,
      copyLabel: _strings.copy,
    );
  }

  // --- Detail pane ---------------------------------------------------------

  /// Swaps the detail pane to [detail], first asking about unsaved edits.
  ///
  /// Changing selection is not a pop, so the editor's own `PopScope` guard
  /// never sees it; without this the next click would drop a half-typed form.
  Future<void> _show(_Detail? detail) async {
    if (_editorDirty && !await confirmDiscardChanges(context)) return;
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _editorDirty = false;
    });
  }

  void _markEditorDirty() {
    if (_editorDirty || !mounted) return;
    setState(() => _editorDirty = true);
  }

  /// Closes the form after a save, reporting [error] if the save failed.
  ///
  /// Editing an agent lands back on its detail view — where the Edit button
  /// was — and everything else falls back to the empty pane, the same place
  /// the pushed editor pops to.
  Future<void> _saved(String? error) async {
    if (!mounted) return;
    if (error != null) _showMessage(error);
    final id = _detail?.id;
    setState(() {
      _editorDirty = false;
      _detail = widget.kind == AgentCenterTab.agents && id != null
          ? _Detail.viewing(id)
          : null;
    });
  }

  /// True when [id] is gone from the catalog, so the pane must let go of it.
  bool _isStale(String id) => switch (widget.kind) {
    AgentCenterTab.agents => _controller.agents.every((a) => a.id != id),
    AgentCenterTab.models => _controller.models.every((m) => m.id != id),
    AgentCenterTab.sources => _controller.sources.every((s) => s.id != id),
    AgentCenterTab.overview => true,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (_controller.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      // The reload that removed an item clears [_detail] too, but it lands a
      // frame later; ignore a stale selection now rather than render an
      // editor for a row that has already left the list.
      final selected = _detail;
      final detail = selected?.id != null && _isStale(selected!.id!)
          ? null
          : selected;

      return LayoutBuilder(
        builder: (context, constraints) {
          // Nothing to sit beside an empty list, so the empty state keeps the
          // full width at every size.
          final twoPane =
              constraints.maxWidth >= catalogTwoPaneBreakpoint && _count > 0;
          if (!twoPane) return _list(twoPane: false, selectedId: null);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _listWidth,
                child: _list(twoPane: true, selectedId: detail?.id),
              ),
              DraggableSeparator(
                onDragUpdate: (deltaX) => setState(() {
                  // The floor keeps a card's title and metrics readable.
                  _listWidth = (_listWidth + deltaX).clamp(280.0, 520.0);
                }),
              ),
              Expanded(child: _detailPane(detail)),
            ],
          );
        },
      );
    },
  );

  Widget _list({required bool twoPane, required String? selectedId}) {
    final items = _items(twoPane: twoPane, selectedId: selectedId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: widget.kind.label,
          addLabel: _addLabel,
          compact: twoPane,
          onAdd: !_canAdd
              ? null
              : twoPane
              ? () => unawaited(_show(const _Detail.creating()))
              : () => context.go(_newPath),
        ),
        if (_count == 0)
          Expanded(child: _emptyState())
        else ...[
          if (_count >= _searchThreshold) _searchField(),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      'No ${widget.kind.label.toLowerCase()} match '
                      '"$_search".',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: items.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: items[i],
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _detailPane(_Detail? detail) {
    if (detail == null) {
      return EmptyState(
        icon: widget.kind.icon,
        title: 'Nothing selected',
        message:
            'Pick $_article from the list to see it here, or add a '
            'new one.',
      );
    }
    if (widget.kind == AgentCenterTab.agents && !detail.editing) {
      return AgentDetailScreen(
        key: ValueKey('detail-${detail.id}'),
        services: widget.services,
        agentId: detail.id!,
        onEdit: (id) => unawaited(_show(_Detail.editing(id))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PaneHeader(
          title: agentEditorTitle(widget.kind, creating: detail.id == null),
          onClose: () => unawaited(
            _show(
              widget.kind == AgentCenterTab.agents && detail.id != null
                  ? _Detail.viewing(detail.id!)
                  : null,
            ),
          ),
        ),
        Expanded(
          child: AgentEditorBody(
            key: ValueKey('editor-${widget.kind.name}-${detail.id}'),
            services: widget.services,
            kind: widget.kind,
            editingId: detail.id,
            onDirty: _markEditorDirty,
            onCancel: () => unawaited(
              _show(
                widget.kind == AgentCenterTab.agents && detail.id != null
                    ? _Detail.viewing(detail.id!)
                    : null,
              ),
            ),
            onSaved: _saved,
          ),
        ),
      ],
    );
  }

  String get _article => switch (widget.kind) {
    AgentCenterTab.agents => 'an agent',
    AgentCenterTab.models => 'a model',
    AgentCenterTab.sources => 'a source',
    AgentCenterTab.overview => 'an item',
  };

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: TextField(
      controller: _searchController,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(LucideIcons.search300, size: 18),
        hintText: 'Search ${widget.kind.label.toLowerCase()}',
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) => setState(() => _search = value),
    ),
  );

  // --- Cards ---------------------------------------------------------------

  List<Widget> _items({required bool twoPane, required String? selectedId}) =>
      switch (widget.kind) {
        AgentCenterTab.agents => [
          for (final agent in _controller.agents)
            if (_matches(agent.name, agent.description))
              _agentCard(agent, twoPane: twoPane, selectedId: selectedId),
        ],
        AgentCenterTab.models => [
          for (final model in _controller.models)
            if (_matches(model.label, model.modelId))
              _modelCard(model, twoPane: twoPane, selectedId: selectedId),
        ],
        AgentCenterTab.sources => [
          for (final source in _controller.sources)
            if (_matches(source.displayName, source.providerType.wireName))
              _sourceCard(source, twoPane: twoPane, selectedId: selectedId),
        ],
        AgentCenterTab.overview => const [],
      };

  Widget _agentCard(
    SavedAgentConfig agent, {
    required bool twoPane,
    required String? selectedId,
  }) {
    final model = _controller.models
        .where((m) => m.id == agent.modelId)
        .firstOrNull;
    final source = model == null
        ? null
        : _controller.sources.where((s) => s.id == model.sourceId).firstOrNull;
    final broken = model == null || source == null;
    final stats = _stats[agent.id];
    return _CatalogCard(
      title: agent.name,
      subtitle: broken
          ? 'Needs setup'
          : '${model.label} · ${source.displayName}',
      subtitleIsWarning: broken,
      selected: twoPane && selectedId == agent.id,
      metrics: stats == null || stats.completed == 0
          ? [const _Metric('No runs yet', '')]
          : [
              _Metric('Runs', '${stats.completed}'),
              _Metric('Success', '${stats.successPercent}%'),
              if (stats.tokens > 0)
                _Metric('Tokens', compactTokens(stats.tokens)),
            ],
      onTap: twoPane
          ? () => unawaited(_show(_Detail.viewing(agent.id)))
          : () => context.go('/settings/agents/view/${agent.id}'),
      onDelete: () => _delete(
        agent.id,
        agent.name,
        (cascade) => _controller.deleteAgent(agent.id, cascade: cascade),
      ),
    );
  }

  Widget _modelCard(
    ModelConfig model, {
    required bool twoPane,
    required String? selectedId,
  }) {
    final source = _controller.sources
        .where((s) => s.id == model.sourceId)
        .firstOrNull;
    final consumers = _controller.agents
        .where((a) => a.modelId == model.id)
        .length;
    return _CatalogCard(
      title: model.label,
      subtitle: source?.displayName ?? 'Source missing',
      subtitleIsWarning: source == null,
      selected: twoPane && selectedId == model.id,
      metrics: [
        _Metric('Used by', consumers == 1 ? '1 agent' : '$consumers agents'),
      ],
      onTap: twoPane
          ? () => unawaited(_show(_Detail.editing(model.id)))
          : () => context.go('/settings/agents/models/edit/${model.id}'),
      onDelete: () => _delete(
        model.id,
        model.label,
        (cascade) => _controller.deleteModel(model.id, cascade: cascade),
      ),
    );
  }

  Widget _sourceCard(
    ModelSourceConfig source, {
    required bool twoPane,
    required String? selectedId,
  }) {
    final models = _controller.models
        .where((m) => m.sourceId == source.id)
        .length;
    return _CatalogCard(
      title: source.displayName,
      subtitle: source.endpoint == null
          ? source.providerType.wireName
          : '${source.providerType.wireName} · ${source.endpoint}',
      selected: twoPane && selectedId == source.id,
      metrics: [_Metric('Models', '$models')],
      onTap: twoPane
          ? () => unawaited(_show(_Detail.editing(source.id)))
          : () => context.go('/settings/agents/sources/edit/${source.id}'),
      onDelete: () => _delete(
        source.id,
        source.displayName,
        (cascade) => _controller.deleteSource(source.id, cascade: cascade),
      ),
    );
  }

  // --- Empty & prerequisites -----------------------------------------------

  Widget _emptyState() {
    final blocked = _prerequisite;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              blocked ?? _emptyMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (blocked != null)
              FilledButton.icon(
                onPressed: () => context.go('/settings/agents/add'),
                icon: const Icon(LucideIcons.wandSparkles300),
                label: const Text('Guided setup'),
              )
            else ...[
              FilledButton.icon(
                onPressed: () => context.go(_newPath),
                icon: const Icon(LucideIcons.plus300),
                label: Text(_addLabel),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go('/settings/agents/add'),
                child: const Text('Guided setup'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool get _canAdd => _prerequisite == null;

  String? get _prerequisite => switch (widget.kind) {
    AgentCenterTab.agents =>
      _controller.models.isEmpty ? _strings.selectModelFirst : null,
    AgentCenterTab.models =>
      _controller.sources.isEmpty
          ? 'Add a source before adding a model.'
          : null,
    _ => null,
  };

  String get _emptyMessage => switch (widget.kind) {
    AgentCenterTab.agents => _strings.noAgents,
    AgentCenterTab.models => _strings.noModels,
    AgentCenterTab.sources => _strings.noSources,
    AgentCenterTab.overview => '',
  };

  String get _addLabel => switch (widget.kind) {
    AgentCenterTab.agents => _strings.addAgent,
    AgentCenterTab.models => _strings.addModel,
    AgentCenterTab.sources => _strings.addSource,
    AgentCenterTab.overview => '',
  };

  String get _newPath => '${widget.kind.path}/new';

  int get _count => switch (widget.kind) {
    AgentCenterTab.agents => _controller.agents.length,
    AgentCenterTab.models => _controller.models.length,
    AgentCenterTab.sources => _controller.sources.length,
    AgentCenterTab.overview => 0,
  };

  bool _matches(String a, String b) {
    final q = _search.trim().toLowerCase();
    return q.isEmpty ||
        a.toLowerCase().contains(q) ||
        b.toLowerCase().contains(q);
  }

  // --- Delete --------------------------------------------------------------

  Future<void> _delete(
    String id,
    String label,
    Future<String?> Function(bool cascade) delete,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_strings.confirmDeleteTitle),
        content: Text('${_strings.confirmDeleteMessage}\n\n$label'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_strings.delete),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    final error = await delete(false);
    if (error == null || !mounted) return;
    // The manager refuses a delete that would orphan dependents and explains
    // what depends on it; offer to take those with it.
    final cascade = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_strings.confirmDeleteTitle),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: error)),
            child: Text(_strings.copy),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_strings.cascadeDelete),
          ),
        ],
      ),
    );
    if (!(cascade ?? false)) return;
    final cascadeError = await delete(true);
    if (cascadeError != null) _showMessage(cascadeError);
  }
}

/// A per-agent run summary shown on its card.
class _AgentStats {
  int succeeded = 0;
  int failed = 0;
  int tokens = 0;

  int get completed => succeeded + failed;
  int get successPercent =>
      completed == 0 ? 0 : (succeeded / completed * 100).round();
}

/// The catalog header: title on the left, an add button on the right.
///
/// Beside a detail pane the list is narrow, so the add button drops to an
/// icon rather than crowding the title out of the row.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.addLabel,
    required this.onAdd,
    this.compact = false,
  });

  final String title;
  final String addLabel;
  final VoidCallback? onAdd;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (compact)
          IconButton.filled(
            tooltip: addLabel,
            onPressed: onAdd,
            icon: const Icon(LucideIcons.plus300, size: 18),
          )
        else
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(LucideIcons.plus300, size: 18),
            label: Text(addLabel),
          ),
      ],
    ),
  );
}

/// The detail pane's title bar, carrying the close affordance the pushed
/// page gets from its app bar's back button.
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(LucideIcons.x300, size: 20),
          onPressed: onClose,
        ),
      ],
    ),
  );
}

/// A tappable catalog card in the Overview's visual language.
class _CatalogCard extends StatelessWidget {
  const _CatalogCard({
    required this.title,
    required this.subtitle,
    required this.metrics,
    required this.onTap,
    required this.onDelete,
    this.subtitleIsWarning = false,
    this.selected = false,
  });

  final String title;
  final String subtitle;
  final bool subtitleIsWarning;
  final List<_Metric> metrics;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// Whether this card's item is the one in the detail pane.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: subtitleIsWarning
                                  ? scheme.error
                                  : selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(LucideIcons.trash2300, size: 18),
                      onPressed: onDelete,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final metric in metrics) ...[
                      metric,
                      const SizedBox(width: 24),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small label/value pair in a card's metric row.
class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (value.isEmpty) {
      return Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleSmall),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

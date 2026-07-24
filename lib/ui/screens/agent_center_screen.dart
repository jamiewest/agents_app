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

import '../dialogs/adaptive_snack_bar/adaptive_snack_bar.dart';
import '../strings/configured_agents_strings.dart';
import '../styles/configured_agents_style.dart';
import 'agent_center_nav.dart';
import '../views/configured_agents/configured_agents.dart';
import '../widgets/app_sliver_header.dart';

/// A catalog within the Agent Center.
enum AgentCenterSection {
  /// Saved agents — the section the Agent Center opens on.
  agents,

  /// Configured models.
  models,

  /// Model sources: on-device runtimes, API providers, and remote agents.
  sources,
}

/// Route paths for each section, and for its create/edit forms.
extension AgentCenterSectionRoutes on AgentCenterSection {
  /// The section's list route.
  String get path => switch (this) {
    AgentCenterSection.agents => '/settings/agents',
    AgentCenterSection.models => '/settings/agents/models',
    AgentCenterSection.sources => '/settings/agents/sources',
  };

  /// The route that creates a new item in this section.
  String get newPath => '$path/new';

  /// The route that edits [id] in this section.
  String editPath(String id) => '$path/edit/$id';

  /// The section's tab label.
  String get label => switch (this) {
    AgentCenterSection.agents => 'Agents',
    AgentCenterSection.models => 'Models',
    AgentCenterSection.sources => 'Sources',
  };

  /// The nav tab this section corresponds to.
  AgentCenterTab get tab => switch (this) {
    AgentCenterSection.agents => AgentCenterTab.agents,
    AgentCenterSection.models => AgentCenterTab.models,
    AgentCenterSection.sources => AgentCenterTab.sources,
  };
}

/// The Agent Center: one surface for saved agents, models, and sources.
///
/// Replaces the three-tab manager. Agents lead because that is what people
/// come here to add or fix; models and sources are the supporting catalogs.
///
/// Tapping an agent opens its detail page (`view/:id`), where Edit is an
/// action — agents carry telemetry worth seeing before editing. Models and
/// sources have none, so tapping one opens its editor directly, via the
/// master-detail layout below.
///
/// That layout follows this screen's own constraints, not the window's:
///
/// * Below [_masterDetailWidth] the list and the editor are separate pages.
///   Selecting a model or source navigates to its edit route, so system back
///   works and a [PopScope] can guard unsaved edits.
/// * At or above it, the editor renders beside the list. Selection there is
///   local state rather than navigation, which keeps a pane swap from
///   animating like a page push; the trade-off is that selection on a wide
///   layout does not update the URL. Deep links into an edit route still
///   open with that item selected.
class AgentCenterScreen extends StatefulWidget {
  /// Creates an [AgentCenterScreen].
  const AgentCenterScreen({
    required this.services,
    this.section = AgentCenterSection.agents,
    this.editingId,
    this.creating = false,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The catalog to show.
  final AgentCenterSection section;

  /// The item to open for editing, when the route names one.
  final String? editingId;

  /// Whether the route asked for a create form.
  final bool creating;

  @override
  State<AgentCenterScreen> createState() => _AgentCenterScreenState();
}

/// Below this width the editor is a separate page rather than a pane.
const double _masterDetailWidth = 1200;

/// At or above this width the section switcher is always visible alongside
/// the content rather than stacked above it.
const double _sideNavWidth = 600;

/// Lists shorter than this are faster to scan than to search.
const int _searchThreshold = 6;

class _AgentCenterScreenState extends State<AgentCenterScreen> {
  late final ConfiguredAgentsController _controller;
  StreamSubscription<void>? _configurationChanges;

  /// The item shown in the editor pane, or null when none is open.
  String? _selectedId;

  /// Whether the open editor is a create form.
  bool _creating = false;

  /// Whether the open editor has unsaved edits.
  bool _dirty = false;

  final _searchController = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    _controller = ConfiguredAgentsController(manager);
    _selectedId = widget.editingId;
    _creating = widget.creating;
    unawaited(_controller.load());
    // The wizard, a cascade delete, or an edit made from a chat all mutate
    // configuration behind this screen's back. Without this the list still
    // shows the pre-wizard state when the user navigates back to it.
    _configurationChanges = manager.configurationChanges.listen((_) async {
      if (!mounted) return;
      await _controller.load();
      if (!mounted) return;
      // A cascade delete elsewhere can remove the item open in the pane.
      // Left alone, the editor would silently become a create form and a
      // Save would mint a new record under a different id.
      final selected = _selectedId;
      if (selected != null && !_currentSectionHas(selected)) {
        setState(() {
          _selectedId = null;
          _creating = false;
          _dirty = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(AgentCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editingId != oldWidget.editingId ||
        widget.creating != oldWidget.creating) {
      _selectedId = widget.editingId;
      _creating = widget.creating;
      _dirty = false;
    }
  }

  @override
  void dispose() {
    unawaited(_configurationChanges?.cancel());
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  ConfiguredAgentsStyle get _style =>
      ConfiguredAgentsStyle.resolveFor(context, null);

  ConfiguredAgentsStrings get _strings =>
      _style.strings ?? ConfiguredAgentsStrings.defaults;

  bool get _editorOpen => _creating || _selectedId != null;

  /// Whether the current section still contains [id].
  bool _currentSectionHas(String id) => _allItems.any((item) => item.id == id);

  void _showMessage(String message) {
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message,
      copyText: message,
      copyLabel: _strings.copy,
    );
  }

  // --- Selection -----------------------------------------------------------

  /// Opens [id] for editing, or the create form when [id] is null.
  ///
  /// On a wide layout this swaps the pane in place; otherwise it navigates
  /// to the item's own route so the back button returns to the list.
  Future<void> _open(String? id, {required bool inline}) async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    if (inline) {
      setState(() {
        _selectedId = id;
        _creating = id == null;
        _dirty = false;
      });
      return;
    }
    context.go(
      id == null ? widget.section.newPath : widget.section.editPath(id),
    );
  }

  /// Closes the editor, returning to the list.
  Future<void> _closeEditor({required bool inline, bool force = false}) async {
    if (!force && !await _confirmDiscard()) return;
    if (!mounted) return;
    if (inline) {
      setState(() {
        _selectedId = null;
        _creating = false;
        _dirty = false;
      });
      return;
    }
    context.go(widget.section.path);
  }

  Future<void> _switchTab(AgentCenterTab tab) async {
    if (tab == widget.section.tab) return;
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    context.go(tab.path);
  }

  /// Asks before throwing away unsaved edits. Silent when nothing changed —
  /// confirming a no-op is exactly the prompt the app's UI rules forbid.
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

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inline = constraints.maxWidth >= _masterDetailWidth;
      final sideNav = constraints.maxWidth >= _sideNavWidth;
      // The guard is on the route pop at every width, not just where the
      // editor is its own page. A wide layout reached by deep link still
      // sits on an edit route, and browser or OS back would otherwise
      // discard the form silently. Discarding always returns to the list
      // route, which is where back was heading.
      return PopScope(
        canPop: !(_editorOpen && _dirty),
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (!await _confirmDiscard() || !mounted) return;
          // Clear the pane as well as the route: on a wide layout the
          // editor may have been opened by selection, in which case the
          // URL is already the list route and navigating alone would
          // leave the form on screen.
          setState(() {
            _selectedId = null;
            _creating = false;
            _dirty = false;
          });
          // The State's own context, not the LayoutBuilder's: `mounted`
          // above guards this one.
          GoRouter.of(this.context).go(widget.section.path);
        },
        child: _editorOpen && !inline
            ? _editorPage()
            : _listScaffold(inline: inline, sideNav: sideNav),
      );
    },
  );

  Widget _listScaffold({required bool inline, required bool sideNav}) =>
      Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader(
              title: 'Agent Center',
              actions: [
                if (!_editorOpen || inline)
                  IconButton(
                    tooltip: _addLabel,
                    icon: const Icon(LucideIcons.plus300),
                    onPressed: _canAdd
                        ? () => _open(null, inline: inline)
                        : null,
                  ),
              ],
            ),
            SliverFillRemaining(
              hasScrollBody: true,
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => _controller.loading
                    ? const Center(child: CircularProgressIndicator())
                    : _body(inline: inline, sideNav: sideNav),
              ),
            ),
          ],
        ),
      );

  Widget _body({required bool inline, required bool sideNav}) {
    final nav = AgentCenterNav(
      current: widget.section.tab,
      vertical: sideNav,
      onSelected: _switchTab,
    );
    final list = _listPane(inline: inline);
    if (!sideNav) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: nav),
          Expanded(child: list),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Row hands unconstrained width to non-flex children, and the
        // vertical switcher stretches its buttons — so it needs a bound.
        SizedBox(
          width: 168,
          child: Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: nav,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(flex: 2, child: list),
        if (inline) ...[
          const VerticalDivider(width: 1),
          Expanded(
            flex: 3,
            child: _editorOpen
                ? _editorPane()
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Select ${_singular.toLowerCase()} to edit, '
                        'or add a new one.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  // --- List ----------------------------------------------------------------

  Widget _listPane({required bool inline}) {
    final items = _visibleItems;
    if (_allItems.isEmpty) return _emptyState(inline: inline);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_allItems.length >= _searchThreshold)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(LucideIcons.search300, size: 18),
                hintText: 'Search ${widget.section.label.toLowerCase()}',
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
        if (items.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No ${widget.section.label.toLowerCase()} match "$_search".',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                // Agents open a detail page (with Edit inside); models and
                // sources have no telemetry to show, so they open the editor
                // directly.
                final opensDetail = widget.section == AgentCenterSection.agents;
                return ListTile(
                  selected: !opensDetail && inline && item.id == _selectedId,
                  title: Text(item.title, style: _style.titleTextStyle),
                  subtitle: item.subtitle == null
                      ? null
                      : Text(item.subtitle!, style: _style.subtitleTextStyle),
                  onTap: opensDetail
                      ? () => context.go('/settings/agents/view/${item.id}')
                      : () => _open(item.id, inline: inline),
                  trailing: IconButton(
                    tooltip: _strings.delete,
                    icon: const Icon(LucideIcons.trash2300),
                    onPressed: () => _delete(item),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _emptyState({required bool inline}) {
    final blocked = _prerequisiteMessage;
    // The guided wizard always builds a source, a model, and an agent, so
    // it is the right primary action only when something upstream is
    // actually missing. With prerequisites already met, adding one item is
    // the obvious next step and the wizard would overshoot.
    final wizard = FilledButton.icon(
      onPressed: () => context.go('/settings/agents/add'),
      icon: const Icon(LucideIcons.wandSparkles300),
      label: const Text('Guided setup'),
    );
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
              wizard
            else ...[
              FilledButton.icon(
                onPressed: () => _open(null, inline: inline),
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

  // --- Editors -------------------------------------------------------------

  Widget _editorPage() => Scaffold(
    appBar: AppBar(title: Text(_editorTitle)),
    body: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _controller.loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: _editor(inline: false),
                ),
              ),
            ),
    ),
  );

  Widget _editorPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _editorTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: _strings.cancel,
              icon: const Icon(LucideIcons.x300),
              onPressed: () => _closeEditor(inline: true),
            ),
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _editor(inline: true),
        ),
      ),
    ],
  );

  Widget _editor({required bool inline}) {
    final style = _style;
    final strings = _strings;
    void markDirty() {
      if (!_dirty && mounted) setState(() => _dirty = true);
    }

    void cancel() => unawaited(_closeEditor(inline: inline, force: true));

    Future<void> finish(String? error) async {
      _dirty = false;
      await _closeEditor(inline: inline, force: true);
      if (error != null) _showMessage(error);
    }

    // A key per edited entity: switching the pane between two items must
    // rebuild the form's controllers rather than leave the previous item's
    // text in the fields.
    final key = ValueKey('${widget.section.name}:${_selectedId ?? 'new'}');

    switch (widget.section) {
      case AgentCenterSection.agents:
        return AgentEditor(
          key: key,
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
          onDirty: markDirty,
          onCancel: cancel,
          onSubmit: (edited) async =>
              finish(await _controller.saveAgent(edited)),
        );
      case AgentCenterSection.models:
        return ModelEditor(
          key: key,
          initial: _find(_controller.models, (m) => m.id),
          sources: _controller.sources,
          style: style,
          strings: strings,
          pickLlamaModelFile: pickDefaultLlamaModelFile,
          onDirty: markDirty,
          onCancel: cancel,
          onSubmit: (edited) async =>
              finish(await _controller.saveModel(edited)),
        );
      case AgentCenterSection.sources:
        return _SourceEditorHost(
          key: key,
          controller: _controller,
          source: _find(_controller.sources, (s) => s.id),
          style: style,
          strings: strings,
          onDirty: markDirty,
          onCancel: cancel,
          onSaved: finish,
        );
    }
  }

  T? _find<T>(List<T> items, String Function(T) id) {
    final selected = _selectedId;
    if (selected == null) return null;
    for (final item in items) {
      if (id(item) == selected) return item;
    }
    return null;
  }

  // --- Delete --------------------------------------------------------------

  Future<void> _delete(_CatalogItem item) async {
    final strings = _strings;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDeleteTitle),
        content: Text('${strings.confirmDeleteMessage}\n\n${item.title}'),
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
    if (!(confirmed ?? false)) return;
    final error = await _deleteItem(item.id, cascade: false);
    if (error == null) {
      if (_selectedId == item.id && mounted) {
        setState(() {
          _selectedId = null;
          _creating = false;
          _dirty = false;
        });
      }
      return;
    }
    if (!mounted) return;
    // The manager refuses a delete that would orphan dependents and explains
    // what depends on it; offer to take those with it.
    final cascade = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDeleteTitle),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: error)),
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
    if (!(cascade ?? false)) return;
    final cascadeError = await _deleteItem(item.id, cascade: true);
    if (cascadeError != null) _showMessage(cascadeError);
  }

  Future<String?> _deleteItem(
    String id, {
    required bool cascade,
  }) => switch (widget.section) {
    AgentCenterSection.agents => _controller.deleteAgent(id, cascade: cascade),
    AgentCenterSection.models => _controller.deleteModel(id, cascade: cascade),
    AgentCenterSection.sources => _controller.deleteSource(
      id,
      cascade: cascade,
    ),
  };

  // --- Section data --------------------------------------------------------

  List<_CatalogItem> get _allItems => switch (widget.section) {
    AgentCenterSection.agents => [
      for (final agent in _controller.agents)
        _CatalogItem(
          agent.id,
          agent.name,
          agent.description.isEmpty ? null : agent.description,
        ),
    ],
    AgentCenterSection.models => [
      for (final model in _controller.models)
        _CatalogItem(
          model.id,
          model.label,
          _controller.sources
                  .where((source) => source.id == model.sourceId)
                  .firstOrNull
                  ?.displayName ??
              model.modelId,
        ),
    ],
    AgentCenterSection.sources => [
      for (final source in _controller.sources)
        _CatalogItem(
          source.id,
          source.displayName,
          source.endpoint == null
              ? source.providerType.wireName
              : '${source.providerType.wireName} · ${source.endpoint}',
        ),
    ],
  };

  List<_CatalogItem> get _visibleItems {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _allItems;
    return [
      for (final item in _allItems)
        if (item.title.toLowerCase().contains(query) ||
            (item.subtitle?.toLowerCase().contains(query) ?? false))
          item,
    ];
  }

  /// Whether the section's prerequisites are met, so adding is possible.
  bool get _canAdd => _prerequisiteMessage == null;

  /// Why this section cannot accept a new item yet, or null when it can.
  String? get _prerequisiteMessage => switch (widget.section) {
    AgentCenterSection.agents =>
      _controller.models.isEmpty ? _strings.selectModelFirst : null,
    AgentCenterSection.models =>
      _controller.sources.isEmpty
          ? 'Add a source before adding a model.'
          : null,
    AgentCenterSection.sources => null,
  };

  String get _emptyMessage => switch (widget.section) {
    AgentCenterSection.agents => _strings.noAgents,
    AgentCenterSection.models => _strings.noModels,
    AgentCenterSection.sources => _strings.noSources,
  };

  String get _addLabel => switch (widget.section) {
    AgentCenterSection.agents => _strings.addAgent,
    AgentCenterSection.models => _strings.addModel,
    AgentCenterSection.sources => _strings.addSource,
  };

  String get _singular => switch (widget.section) {
    AgentCenterSection.agents => 'an agent',
    AgentCenterSection.models => 'a model',
    AgentCenterSection.sources => 'a source',
  };

  String get _editorTitle => switch ((widget.section, _creating)) {
    (AgentCenterSection.agents, true) => _strings.addAgent,
    (AgentCenterSection.agents, false) => _strings.editAgent,
    (AgentCenterSection.models, true) => _strings.addModel,
    (AgentCenterSection.models, false) => _strings.editModel,
    (AgentCenterSection.sources, true) => _strings.addSource,
    (AgentCenterSection.sources, false) => _strings.editSource,
  };
}

/// One row in a catalog list.
class _CatalogItem {
  const _CatalogItem(this.id, this.title, this.subtitle);

  final String id;
  final String title;
  final String? subtitle;
}

/// Hosts [SourceEditor], which needs to know whether a key is already stored
/// before it can render, and adds the web key-storage caveat.
class _SourceEditorHost extends StatefulWidget {
  const _SourceEditorHost({
    required this.controller,
    required this.source,
    required this.style,
    required this.strings,
    required this.onDirty,
    required this.onCancel,
    required this.onSaved,
    super.key,
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
///
/// Carried over from the retired manager screen: it is the only place the
/// user learns that browser storage is not a keychain.
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

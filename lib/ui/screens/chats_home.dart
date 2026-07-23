// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/channel_store.dart';
import '../../data/chat_transcript_store.dart';
import '../../data/conversation_store.dart';
import '../../data/usage_store.dart';
import '../../domain/channel.dart';
import '../../domain/chats_filter.dart';
import '../../domain/conversation.dart';
import '../../main.dart' show ChatScreen;
import '../app_theme.dart';
import '../widgets/app_sliver_header.dart';
import '../widgets/chats_filter_bar.dart';
import '../widgets/chats_filter_sheet.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/draggable_separator.dart';
import '../widgets/empty_state.dart';

/// The width at which the chats branch shows list and detail side by side.
const double twoPaneBreakpoint = 1000;

/// Shares the chats layout mode down to the panes built by the inner
/// navigator, so the branch root and the open chat agree with [ChatsHome]
/// on whether the persistent sidebar is showing, and can toggle it.
class ChatsScope extends InheritedWidget {
  /// Creates a [ChatsScope].
  const ChatsScope({
    required this.twoPane,
    required this.sidebarCollapsed,
    required this.onToggleSidebar,
    required super.child,
    this.filters,
    super.key,
  });

  /// Whether the layout is wide enough for the sidebar and detail pane to
  /// be shown side by side.
  final bool twoPane;

  /// Whether the sidebar is currently collapsed out of the two-pane layout.
  final bool sidebarCollapsed;

  /// Toggles the sidebar open/closed, or null when the layout has no
  /// sidebar (compact widths).
  final VoidCallback? onToggleSidebar;

  /// The shared search/filter/sort state for every [ChatsListView] in this
  /// scope. Owned by [ChatsHome] so it survives sidebar collapse/restore
  /// and navigation; null outside the chats shell.
  final ChatsFilterController? filters;

  /// The nearest [ChatsScope], or null outside the chats branch.
  static ChatsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatsScope>();

  /// Whether the nearest [ChatsHome] is in its two-pane (wide) layout.
  static bool twoPaneOf(BuildContext context) =>
      maybeOf(context)?.twoPane ?? false;

  @override
  bool updateShouldNotify(ChatsScope oldWidget) =>
      twoPane != oldWidget.twoPane ||
      sidebarCollapsed != oldWidget.sidebarCollapsed ||
      onToggleSidebar != oldWidget.onToggleSidebar ||
      filters != oldWidget.filters;
}

/// The detail-pane button that opens/closes the conversations sidebar:
/// the persistent two-pane sidebar on wide layouts, or the conversations
/// drawer on single-pane widths that host one.
///
/// Uses the sidebar glyph: filled while the sidebar is open, outlined while
/// it is collapsed. Renders nothing when the layout has no sidebar to
/// toggle (compact widths), so it can sit unconditionally in embedded app
/// bars.
class SidebarToggleButton extends StatelessWidget {
  /// Creates a [SidebarToggleButton].
  const SidebarToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = ChatsScope.maybeOf(context);
    final onToggle = scope?.onToggleSidebar;
    if (scope == null || onToggle == null) return const SizedBox.shrink();
    final collapsed = scope.sidebarCollapsed;
    return IconButton(
      tooltip: collapsed ? 'Show conversations' : 'Hide conversations',
      icon: collapsed
          ? Icon(LucideIcons.panelRightClose300)
          : Icon(LucideIcons.panelRightOpen300),
      onPressed: onToggle,
    );
  }
}

/// The app-bar leading configuration for detail panes (open chats and
/// channels).
///
/// Two-pane layouts show only the [SidebarToggleButton]: the persistent
/// sidebar handles navigation, so the back button is dropped. Single-pane
/// layouts that host the conversations drawer pair the back button with the
/// toggle, which needs the wider `leadingWidth`. Elsewhere both values are
/// null so the app bar falls back to the implied back button.
({Widget? leading, double? leadingWidth}) detailPaneLeading(
  BuildContext context,
) {
  final scope = ChatsScope.maybeOf(context);
  if (scope == null || scope.onToggleSidebar == null) {
    return (leading: null, leadingWidth: null);
  }
  if (scope.twoPane) {
    return (leading: const SidebarToggleButton(), leadingWidth: null);
  }
  return (
    leading: const Row(children: [BackButton(), SidebarToggleButton()]),
    leadingWidth: 96,
  );
}

/// The Chats destination shell: a persistent conversations/channels sidebar
/// beside the inner navigator that hosts the open chat, channel, or an
/// empty-state placeholder.
///
/// This is the *inner* stateful shell. On wide layouts it lays the sidebar
/// and the detail navigator ([navigationShell]) side by side; on compact
/// widths it shows only the navigator, whose root renders the list.
class ChatsHome extends StatefulWidget {
  /// Creates a [ChatsHome].
  const ChatsHome({
    required this.services,
    required this.navigationShell,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The inner navigator hosting the branch root and the open detail route.
  final StatefulNavigationShell navigationShell;

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  final _drawerKey = GlobalKey<ScaffoldState>();
  final ChatsFilterController _filters = ChatsFilterController();
  double _sidebarWidth = 300;
  bool _sidebarCollapsed = false;

  @override
  void dispose() {
    _filters.dispose();
    super.dispose();
  }

  void _toggleSidebar() =>
      setState(() => _sidebarCollapsed = !_sidebarCollapsed);

  void _openSidebarDrawer() => _drawerKey.currentState?.openDrawer();

  /// The conversation the detail navigator currently shows, parsed from the
  /// live location so the sidebar can highlight it and route deletions.
  String? _selectedConversationId(BuildContext context) {
    final segments = GoRouterState.of(context).uri.pathSegments;
    if (segments.length >= 3 && segments[0] == 'chats' && segments[1] == 'c') {
      return segments[2];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Sized from our own constraints (not the window): the adaptive shell
    // reclaims width for the rail, and the body must degrade gracefully.
    builder: (context, constraints) {
      final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
      // Medium widths get the conversations list in a modal drawer so an
      // open chat can still reach it; compact widths already have the
      // shell drawer and back navigation.
      final drawerSidebar = !twoPane && !Breakpoints.small.isActive(context);
      final selectedId = _selectedConversationId(context);
      return ChatsScope(
        twoPane: twoPane,
        filters: _filters,
        sidebarCollapsed: twoPane ? _sidebarCollapsed : true,
        onToggleSidebar: twoPane
            ? _toggleSidebar
            : drawerSidebar
            ? _openSidebarDrawer
            : null,
        child: twoPane
            ? Row(
                children: [
                  if (!_sidebarCollapsed) ...[
                    SizedBox(
                      width: _sidebarWidth,
                      child: ChatsListView(
                        services: widget.services,
                        presentation: ChatsListPresentation.sidebar,
                        selectedConversationId: selectedId,
                      ),
                    ),
                    DraggableSeparator(
                      onDragUpdate: (deltaX) => setState(() {
                        // The floor keeps the brand + actions on one line.
                        _sidebarWidth = (_sidebarWidth + deltaX).clamp(
                          248.0,
                          480.0,
                        );
                      }),
                    ),
                  ],
                  Expanded(child: widget.navigationShell),
                ],
              )
            : drawerSidebar
            ? Scaffold(
                key: _drawerKey,
                drawer: Drawer(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    child: ChatsListView(
                      services: widget.services,
                      presentation: ChatsListPresentation.drawer,
                      selectedConversationId: selectedId,
                    ),
                  ),
                ),
                body: widget.navigationShell,
              )
            : widget.navigationShell,
      );
    },
  );
}

/// The inner navigator's root: the conversation list on compact widths, or
/// a "pick a conversation" placeholder when the sidebar already shows the
/// list beside it.
class ChatsRootPane extends StatelessWidget {
  /// Creates a [ChatsRootPane].
  const ChatsRootPane({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    if (ChatsScope.twoPaneOf(context)) {
      return Stack(
        children: [
          const Positioned(
            top: AppSpacing.sm,
            left: AppSpacing.sm,
            child: SafeArea(child: SidebarToggleButton()),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.messagesSquare300,
                  size: 56,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Select a conversation or start a new chat.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ChatsListView(
      services: services,
      presentation: ChatsListPresentation.page,
    );
  }
}

/// How a [ChatsListView] frames its conversation/channel list.
enum ChatsListPresentation {
  /// A full screen with an app bar and a new-chat FAB (compact layouts).
  page,

  /// A branded side panel with a header and New Conversation button.
  sidebar,

  /// The sidebar layout hosted inside a navigation drawer (the compact
  /// shell drawer, or the chats drawer on medium single-pane widths);
  /// navigating from it closes the drawer.
  drawer,
}

/// The conversations and channels list, shown either as a full page or as
/// the persistent sidebar.
///
/// Owns the stores, live streams, and the new-chat / new-channel / rename /
/// delete actions; navigation is driven through the router.
class ChatsListView extends StatefulWidget {
  /// Creates a [ChatsListView].
  const ChatsListView({
    required this.services,
    required this.presentation,
    this.selectedConversationId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// How the list frames itself.
  final ChatsListPresentation presentation;

  /// The open conversation to highlight, when shown as the sidebar beside a
  /// detail pane.
  final String? selectedConversationId;

  @override
  State<ChatsListView> createState() => _ChatsListViewState();
}

class _ChatsListViewState extends State<ChatsListView> {
  late final ConversationStore _conversations;
  late final ConversationSessionStore _sessions;
  late final ChatTranscriptStore _transcripts;
  late final UsageStore _usage;
  late final ChannelStore _channels;
  late final ConfiguredAgentsManager _manager;
  late final Stream<List<Conversation>> _conversationStream;
  late final Stream<List<Channel>> _channelStream;
  AgentFilterIndex _index = AgentFilterIndex();
  bool _initialized = false;
  StreamSubscription<void>? _configurationChangesSub;

  /// Search/filter/sort state: the shell-owned controller from [ChatsScope]
  /// when available (so it outlives this widget), else a locally owned one.
  late ChatsFilterController _filters;
  ChatsFilterController? _attachedFilters;
  ChatsFilterController? _ownedFilters;
  final TextEditingController _searchController = TextEditingController();

  Map<String, SavedAgentConfig> get _agentsById => _index.agentsById;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachFilters();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
    _sessions = ConversationSessionStore(records);
    _transcripts = ChatTranscriptStore(records);
    _usage = UsageStore(records);
    _channels = ChannelStore(records);
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    // Broadcast: the adaptive shell can briefly mount two copies of a body
    // while animating slot changes.
    _conversationStream = _conversations.watchAll().asBroadcastStream();
    _channelStream = _channels.watchAll().asBroadcastStream();
    // Renames, additions, and deletions in Settings should show here
    // without remounting the list; capability and provider filters also
    // depend on model/source records, so listen to the general stream.
    _configurationChangesSub = _manager.configurationChanges.listen(
      (_) => _loadConfiguration(),
    );
    _loadConfiguration();
  }

  void _attachFilters() {
    final resolved =
        ChatsScope.maybeOf(context)?.filters ??
        (_ownedFilters ??= ChatsFilterController());
    if (identical(resolved, _attachedFilters)) return;
    _attachedFilters?.removeListener(_onQueryChanged);
    _attachedFilters = resolved;
    _filters = resolved;
    resolved.addListener(_onQueryChanged);
    if (_searchController.text != resolved.query.searchText) {
      _searchController.text = resolved.query.searchText;
    }
  }

  void _onQueryChanged() {
    if (!mounted) return;
    setState(() {
      // Leaving the filtered view drops the transient auto-expansion so the
      // user's saved section choices come back untouched.
      if (!_filters.query.isActive) _filteredSectionExpanded.clear();
      if (_searchController.text != _filters.query.searchText) {
        _searchController.text = _filters.query.searchText;
      }
    });
  }

  @override
  void dispose() {
    _configurationChangesSub?.cancel();
    _attachedFilters?.removeListener(_onQueryChanged);
    _ownedFilters?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _agentReloadScheduled = false;

  Future<void> _loadConfiguration() async {
    final agents = await _manager.agents.listAgents();
    final models = await _manager.sources.listModels();
    final sources = await _manager.sources.listSources();
    _agentReloadScheduled = false;
    if (!mounted) return;
    setState(() {
      _index = AgentFilterIndex(
        agents: agents,
        models: models,
        sources: sources,
      );
    });
  }

  /// Reloads the configuration when the list mentions an agent we have not
  /// seen — e.g. one added in Settings after this screen was first built.
  void _ensureAgentsFor(List<Conversation> conversations) {
    if (_agentReloadScheduled) return;
    final unknown = conversations.any(
      (conversation) => !_agentsById.containsKey(conversation.primaryAgentId),
    );
    if (unknown) {
      _agentReloadScheduled = true;
      Future<void>.microtask(_loadConfiguration);
    }
  }

  Future<void> _startNewChat() async {
    _closeDrawerIfHostedInOne();
    await _loadConfiguration();
    if (!mounted) return;
    final agents = _agentsById.values.toList();
    if (agents.isEmpty) {
      // No agents yet: send the user to the guided wizard and say why.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an agent to start chatting.')),
      );
      context.go('/settings/agents/add');
      return;
    }
    final selected =
        await showModalBottomSheet<(SavedAgentConfig, {bool private})>(
          context: context,
          builder: (context) {
            var private = false;
            return SafeArea(
              child: StatefulBuilder(
                builder: (context, setSheetState) => ListView(
                  shrinkWrap: true,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Start a chat with…'),
                    ),
                    SwitchListTile(
                      value: private,
                      onChanged: (value) =>
                          setSheetState(() => private = value),
                      secondary: const Icon(LucideIcons.eyeOff300),
                      title: const Text('Private chat'),
                      subtitle: const Text('Nothing is saved'),
                    ),
                    const Divider(height: 1),
                    for (final agent in agents)
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(_initialFor(agent.name)),
                        ),
                        title: Text(agent.name),
                        subtitle: agent.description.isEmpty
                            ? null
                            : Text(
                                agent.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.of(
                          context,
                        ).pop((agent, private: private)),
                      ),
                  ],
                ),
              ),
            );
          },
        );
    if (selected != null && mounted) {
      final (agent, :private) = selected;
      context.go('/chats/new/${agent.id}${private ? '?private=1' : ''}');
    }
  }

  static String _initialFor(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  Future<void> _createChannel() async {
    _closeDrawerIfHostedInOne();
    var name = '';
    final submitted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New channel'),
        content: TextFormField(
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Research',
          ),
          onChanged: (value) => name = value,
          onFieldSubmitted: (_) {
            if (name.trim().isNotEmpty) {
              Navigator.of(context).pop(name.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.trim().isNotEmpty) {
                Navigator.of(context).pop(name.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (submitted == null || !mounted) return;

    final now = DateTime.now();
    final channel = Channel(
      id: _channels.newChannelId(),
      name: submitted,
      createdAt: now,
      updatedAt: now,
    );
    await _channels.save(channel);
    if (mounted) context.go('/chats/channel/${channel.id}');
  }

  @override
  Widget build(BuildContext context) => switch (widget.presentation) {
    ChatsListPresentation.page => _buildPage(context),
    ChatsListPresentation.sidebar ||
    ChatsListPresentation.drawer => _buildSidebar(context),
  };

  /// Closes the enclosing shell drawer when hosted in one, so navigating
  /// (or opening a sheet/dialog) doesn't leave the drawer open behind it.
  void _closeDrawerIfHostedInOne() {
    if (widget.presentation != ChatsListPresentation.drawer) return;
    Scaffold.maybeOf(context)?.closeDrawer();
  }

  /// The compact-width Chats page: app bar, list, and a new-chat FAB.
  Widget _buildPage(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      tooltip: 'New chat',
      onPressed: _startNewChat,
      child: const Icon(LucideIcons.messageSquarePlus300),
    ),
    body: _buildStreamed(context, (channels, conversations) {
      final hasData =
          channels.isNotEmpty || (conversations?.isNotEmpty ?? false);
      final filtered = conversations == null
          ? null
          : _applyQuery(channels, conversations);
      return CustomScrollView(
        slivers: [
          AppSliverHeader(
            title: 'Chats',
            actions: [
              IconButton(
                tooltip: 'New channel',
                icon: const Icon(LucideIcons.hash300),
                onPressed: _createChannel,
              ),
            ],
          ),
          if (conversations != null && hasData)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: _buildFilterBar(context),
              ),
            ),
          if (conversations == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!hasData)
            SliverFillRemaining(hasScrollBody: false, child: _buildEmptyState())
          else if (filtered!.channels.isEmpty && filtered.conversations.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildNoMatchesState(context),
            )
          else
            SliverList.list(
              children: _listChildren(
                context,
                filtered.channels,
                filtered.conversations,
              ),
            ),
        ],
      );
    }),
  );

  /// The persistent, branded sidebar shown beside the chat on wide layouts.
  ///
  /// A [Material] (not a plain [ColoredBox]) because the search field needs
  /// a material ancestor even when the sidebar sits outside any Scaffold.
  Widget _buildSidebar(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SidebarHeader(onNewChat: _startNewChat, onNewChannel: _createChannel),
        Expanded(
          child: _buildStreamed(context, (channels, conversations) {
            if (conversations == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (conversations.isEmpty && channels.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Text(
                  'No conversations yet',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            final filtered = _applyQuery(channels, conversations);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: _buildFilterBar(context),
                ),
                Expanded(
                  child:
                      filtered.channels.isEmpty &&
                          filtered.conversations.isEmpty
                      ? _buildNoMatchesState(context)
                      : ListView(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.xs,
                          ),
                          children: _listChildren(
                            context,
                            filtered.channels,
                            filtered.conversations,
                          ),
                        ),
                ),
              ],
            );
          }),
        ),
      ],
    ),
  );

  Widget _buildFilterBar(BuildContext context) => ChatsFilterBar(
    searchController: _searchController,
    query: _filters.query,
    agentNameOf: (agentId) => _agentsById[agentId]?.name ?? 'Unknown agent',
    onQueryChanged: (query) => _filters.query = query,
    onOpenFilters: _openFilterSheet,
  );

  Future<void> _openFilterSheet() async {
    final agents = _agentsById.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final result = await showChatsFilterSheet(
      context,
      query: _filters.query,
      agents: agents,
    );
    if (result != null) _filters.query = result;
  }

  /// Applies the active query; a pass-through when nothing is active.
  ({List<Channel> channels, List<Conversation> conversations}) _applyQuery(
    List<Channel> channels,
    List<Conversation> conversations,
  ) {
    final query = _filters.query;
    if (!query.isActive) {
      return (channels: channels, conversations: conversations);
    }
    final now = DateTime.now();
    return (
      channels: [
        for (final channel in channels)
          if (channelMatchesQuery(channel, query, _index, now: now)) channel,
      ],
      conversations: [
        for (final conversation in conversations)
          if (conversationMatchesQuery(conversation, query, _index, now: now))
            conversation,
      ],
    );
  }

  /// Subscribes to the channel and conversation streams and hands the
  /// latest snapshot (conversations `null` until first loaded) to [builder].
  Widget _buildStreamed(
    BuildContext context,
    Widget Function(List<Channel> channels, List<Conversation>? conversations)
    builder,
  ) => StreamBuilder<List<Channel>>(
    stream: _channelStream,
    builder: (context, channelSnapshot) => StreamBuilder<List<Conversation>>(
      stream: _conversationStream,
      builder: (context, snapshot) {
        final channels = channelSnapshot.data ?? const <Channel>[];
        final conversations = snapshot.data;
        if (conversations != null) _ensureAgentsFor(conversations);
        return builder(channels, conversations);
      },
    ),
  );

  /// Explicit user toggles, kept for this list's lifetime: the page and
  /// sidebar presentations stay mounted across navigation, while a freshly
  /// opened drawer starts back at the collapsed defaults.
  final Map<String, bool> _sectionExpanded = {};

  /// Toggles made while a search/filter is active. Kept apart from
  /// [_sectionExpanded] so auto-expanding matches never overwrites the
  /// user's saved choices; cleared when the query goes inactive.
  final Map<String, bool> _filteredSectionExpanded = {};

  /// Whether the section is open. While a query is active, sections with
  /// matches auto-expand (transient toggles still win); otherwise an
  /// explicit user toggle wins and sections start collapsed except the one
  /// holding the open conversation.
  bool _isExpanded(String key, {required bool containsSelection}) {
    if (_filters.query.isActive) return _filteredSectionExpanded[key] ?? true;
    return _sectionExpanded[key] ?? containsSelection;
  }

  void _toggleSection(String key, {required bool expanded}) => setState(() {
    if (_filters.query.isActive) {
      _filteredSectionExpanded[key] = !expanded;
    } else {
      _sectionExpanded[key] = !expanded;
    }
  });

  /// Builds the grouped, collapsible list. Currently the only grouping is
  /// channels / group chats / by-agent; future view types (e.g. all agents
  /// grouped by date) become alternate section builders feeding the same
  /// [_CollapsibleSection] widgets.
  List<Widget> _listChildren(
    BuildContext context,
    List<Channel> channels,
    List<Conversation> conversations,
  ) {
    final order = _filters.query.sortOrder;
    final groupChats = <Conversation>[];
    final byAgent = <String, List<Conversation>>{};
    for (final conversation in conversations) {
      if (conversation.kind == ConversationKind.group) {
        groupChats.add(conversation);
      } else {
        byAgent
            .putIfAbsent(conversation.primaryAgentId, () => [])
            .add(conversation);
      }
    }
    final sortedChannels = sortChannels(channels, order);
    final sortedGroups = sortGroupConversations(groupChats, order, _index);
    return [
      if (sortedChannels.isNotEmpty)
        _section(
          key: 'channels',
          title: 'Channels',
          count: sortedChannels.length,
          containsSelection: false,
          unread: false,
          children: [
            for (final channel in sortedChannels)
              _channelTile(context, channel),
          ],
        ),
      if (sortedGroups.isNotEmpty)
        _conversationSection(
          context,
          key: 'group-chats',
          title: 'Group chats',
          conversations: sortedGroups,
        ),
      for (final agentId in orderAgentSections(byAgent, order, _index))
        _conversationSection(
          context,
          key: 'agent:$agentId',
          title: _agentsById[agentId]?.name ?? 'Unknown agent',
          conversations: sortSectionConversations(
            byAgent[agentId]!,
            order,
            _index,
          ),
        ),
    ];
  }

  Widget _conversationSection(
    BuildContext context, {
    required String key,
    required String title,
    required List<Conversation> conversations,
  }) => _section(
    key: key,
    title: title,
    count: conversations.length,
    containsSelection: conversations.any(
      (conversation) => conversation.id == widget.selectedConversationId,
    ),
    unread: conversations.any((conversation) => conversation.hasUnread),
    children: [
      for (final conversation in conversations)
        _conversationTile(context, conversation),
    ],
  );

  Widget _section({
    required String key,
    required String title,
    required int count,
    required bool containsSelection,
    required bool unread,
    required List<Widget> children,
  }) {
    final expanded = _isExpanded(key, containsSelection: containsSelection);
    return _CollapsibleSection(
      title: title,
      count: count,
      unread: unread,
      expanded: expanded,
      onToggle: () => _toggleSection(key, expanded: expanded),
      children: children,
    );
  }

  Widget _buildEmptyState() => EmptyState(
    icon: LucideIcons.messagesSquare300,
    title: 'No conversations yet',
    message:
        'Start a chat with one of your agents — they pick up right '
        'where you left off.',
    actionLabel: 'New chat',
    onAction: _startNewChat,
  );

  /// Shown when conversations exist but none survive the active query.
  Widget _buildNoMatchesState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.searchX300,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No matching conversations',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Try different search terms or remove some filters.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(
              onPressed: () => _filters.query = ChatsQuery(
                sortOrder: _filters.query.sortOrder,
              ),
              child: const Text('Clear search and filters'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final title = await showRenameDialog(
      context,
      dialogTitle: 'Rename conversation',
      initialTitle: conversation.title,
    );
    if (title == null) return;
    await _conversations.save(
      conversation.copyWith(
        title: title,
        titleSource: ConversationTitleSource.manual,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final deleted = await confirmAndDeleteConversation(
      context,
      conversationId: conversation.id,
      title: conversationDisplayTitle(conversation),
      conversations: _conversations,
      sessions: _sessions,
      transcripts: _transcripts,
      usage: _usage,
    );
    if (deleted &&
        mounted &&
        conversation.id == widget.selectedConversationId) {
      context.go('/chats');
    }
  }

  Future<void> _renameChannel(Channel channel) async {
    final name = await showRenameDialog(
      context,
      dialogTitle: 'Rename channel',
      initialTitle: channel.name,
    );
    if (name == null) return;
    await _channels.save(
      channel.copyWith(name: name, updatedAt: DateTime.now()),
    );
  }

  Future<void> _deleteChannel(Channel channel) async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete channel?',
      message:
          'Delete "${channel.name}"? Its conversations are kept and stay '
          'available in Chats.',
      confirmLabel: 'Delete channel',
    );
    if (!confirmed) return;
    await _channels.delete(channel.id);
  }

  Widget _channelTile(BuildContext context, Channel channel) => _EntryTile(
    leading: Icon(
      LucideIcons.hash300,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    title: channel.name,
    subtitle: channel.description.isEmpty ? null : channel.description,
    selected: false,
    onTap: () {
      _closeDrawerIfHostedInOne();
      context.go('/chats/channel/${channel.id}');
    },
    menuTooltip: 'Channel actions',
    onRename: () => unawaited(_renameChannel(channel)),
    onDelete: () => unawaited(_deleteChannel(channel)),
  );

  Widget _conversationTile(BuildContext context, Conversation conversation) {
    final agent = _agentsById[conversation.primaryAgentId];
    final selected = conversation.id == widget.selectedConversationId;
    final agentName = agent?.name;
    final conversationTitle = conversation.title.trim();
    // The agent name lives in the section header, so the tile only needs
    // the conversation's own title.
    final title = conversationTitle.isEmpty
        ? (agentName ?? 'Untitled conversation')
        : conversationTitle;
    final preview = conversation.lastMessagePreview?.trim();
    final isGroup = conversation.kind == ConversationKind.group;
    return _EntryTile(
      leading: CircleAvatar(
        radius: 14,
        child: isGroup
            ? const Icon(LucideIcons.users300, size: 16)
            : Text(
                _initialFor(agentName ?? title),
                style: Theme.of(context).textTheme.labelMedium,
              ),
      ),
      title: title,
      subtitle: (preview == null || preview.isEmpty) ? null : preview,
      selected: selected,
      unread: conversation.hasUnread,
      onTap: () {
        _closeDrawerIfHostedInOne();
        context.go('/chats/c/${conversation.id}');
      },
      menuTooltip: 'Conversation actions',
      onRename: () => unawaited(_renameConversation(conversation)),
      onDelete: () => unawaited(_deleteConversation(conversation)),
    );
  }
}

/// The open conversation, channel, or new chat, resolved from its saved
/// agent and rendered as the inner navigator's detail page.
class ChatDetailPane extends StatefulWidget {
  /// Creates a [ChatDetailPane].
  const ChatDetailPane({
    required this.services,
    this.conversationId,
    this.newChatAgentId,
    this.privateChat = false,
    this.channelId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The conversation to resume, when resuming one.
  final String? conversationId;

  /// The agent to start a new conversation with, when starting one.
  final String? newChatAgentId;

  /// Whether a new chat should be private (nothing persisted).
  final bool privateChat;

  /// The channel a new chat should belong to, when started from one.
  final String? channelId;

  @override
  State<ChatDetailPane> createState() => _ChatDetailPaneState();
}

class _ChatDetailPaneState extends State<ChatDetailPane> {
  late final ConfiguredAgentsManager _manager;
  late final ConversationStore _conversations;
  late final Future<SavedAgentConfig?> _agentFuture;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    _agentFuture = _resolveAgent();
  }

  Future<SavedAgentConfig?> _resolveAgent() async {
    final newChatAgentId = widget.newChatAgentId;
    if (newChatAgentId != null) {
      return _manager.agents.getAgent(newChatAgentId);
    }
    final conversation = await _conversations.get(widget.conversationId!);
    if (conversation == null) return null;
    // Group conversations run through their coordinator.
    return _manager.agents.getAgent(
      conversation.coordinatorAgentId ?? conversation.primaryAgentId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final embedded = ChatsScope.twoPaneOf(context);
    return FutureBuilder<SavedAgentConfig?>(
      future: _agentFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final agent = snapshot.data;
        if (agent == null) {
          final leading = detailPaneLeading(context);
          return Scaffold(
            appBar: AppBar(
              leadingWidth: leading.leadingWidth,
              leading: leading.leading,
            ),
            body: const Center(
              child: Text('This conversation\'s agent no longer exists.'),
            ),
          );
        }
        return ChatScreen(
          key: ValueKey(
            widget.conversationId ?? 'new-${widget.newChatAgentId}',
          ),
          agent: agent,
          services: widget.services,
          conversationId: widget.conversationId,
          embedded: embedded,
          isPrivate: widget.conversationId == null && widget.privateChat,
          channelId: widget.channelId,
        );
      },
    );
  }
}

/// The sidebar's brand header and New Conversation button.
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.onNewChat, required this.onNewChannel});

  final VoidCallback onNewChat;
  final VoidCallback onNewChannel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.circleDotDashed300,
                color: scheme.primary,
                size: 24,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'AGENT TEAMS',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'New channel',
                icon: const Icon(LucideIcons.hash300, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: onNewChannel,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.small),
              ),
            ),
            onPressed: onNewChat,
            icon: const Icon(LucideIcons.plus300, size: 18),
            label: const Text(
              'New Conversation',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact stadium-shaped list tile for conversations and channels,
/// with an inline Rename/Delete menu.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.menuTooltip,
    required this.onRename,
    required this.onDelete,
    this.subtitle,
    this.unread = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String menuTooltip;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  /// Whether to show an unread dot and emphasize the title.
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      child: Material(
        shape: const StadiumBorder(),
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 6,
            ),
            child: Row(
              children: [
                leading,
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? scheme.onSecondaryContainer
                              : scheme.onSurface,
                          fontWeight: selected || unread
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? scheme.onSecondaryContainer.withValues(
                                    alpha: 0.7,
                                  )
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (unread)
                  Container(
                    margin: const EdgeInsets.only(left: AppSpacing.sm),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                PopupMenuButton<void Function()>(
                  tooltip: menuTooltip,
                  onSelected: (action) => action(),
                  icon: Icon(
                    LucideIcons.ellipsis300,
                    size: 18,
                    color: selected
                        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
                        : scheme.onSurfaceVariant,
                  ),
                  iconSize: 18,
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  constraints: const BoxConstraints(),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: onRename,
                      child: const Row(
                        children: [
                          Icon(LucideIcons.pencil300, size: 18),
                          SizedBox(width: AppSpacing.md),
                          Text('Rename'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: onDelete,
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.trash2300,
                            size: 18,
                            color: scheme.error,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Text('Delete', style: TextStyle(color: scheme.error)),
                        ],
                      ),
                    ),
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

/// A collapsible group in the conversations list: a tappable header with
/// the section title, entry count, an unread dot while collapsed, and a
/// rotating chevron, above the section's tiles.
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.count,
    required this.unread,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final String title;
  final int count;

  /// Whether the section holds unread conversations (surfaced on the header
  /// only while collapsed, since open sections show the per-tile dots).
  final bool unread;

  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
            1,
          ),
          child: Material(
            shape: const StadiumBorder(),
            color: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    if (unread && !expanded)
                      Container(
                        margin: const EdgeInsets.only(right: AppSpacing.sm),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppShape.small),
                      ),
                      child: Text(
                        '$count',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: Icon(
                        LucideIcons.chevronDown300,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

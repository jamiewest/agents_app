// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/channel_store.dart';
import '../../data/chat_transcript_store.dart';
import '../../data/conversation_store.dart';
import '../../domain/channel.dart';
import '../../domain/conversation.dart';
import '../../main.dart' show ChatScreen;
import '../app_theme.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/draggable_separator.dart';
import '../widgets/empty_state.dart';

/// The width at which the chats branch shows list and detail side by side.
const double twoPaneBreakpoint = 1000;

/// The Chats destination: the conversation list plus, when a conversation
/// (or new chat) is selected, its [ChatScreen].
///
/// Compact widths show either the list or the open chat; wide layouts show
/// both panes side by side.
class ChatsHome extends StatefulWidget {
  /// Creates a [ChatsHome].
  const ChatsHome({
    required this.services,
    this.conversationId,
    this.newChatAgentId,
    this.privateChat = false,
    this.channelId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The open conversation, when resuming one.
  final String? conversationId;

  /// The agent to start a new conversation with, when starting one.
  final String? newChatAgentId;

  /// Whether a new chat should be private (nothing persisted).
  final bool privateChat;

  /// The channel a new chat should belong to, when started from one.
  final String? channelId;

  @override
  State<ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<ChatsHome> {
  late final ConversationStore _conversations;
  late final ConversationSessionStore _sessions;
  late final ChatTranscriptStore _transcripts;
  late final ChannelStore _channels;
  late final ConfiguredAgentsManager _manager;
  late final Stream<List<Conversation>> _conversationStream;
  late final Stream<List<Channel>> _channelStream;
  Map<String, SavedAgentConfig> _agentsById = const {};
  bool _initialized = false;
  double _sidebarWidth = 300;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
    _sessions = ConversationSessionStore(records);
    _transcripts = ChatTranscriptStore(records);
    _channels = ChannelStore(records);
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    // Broadcast: the adaptive shell can briefly mount two copies of this
    // body while animating slot changes.
    _conversationStream = _conversations.watchAll().asBroadcastStream();
    _channelStream = _channels.watchAll().asBroadcastStream();
    _loadAgents();
  }

  bool _agentReloadScheduled = false;

  Future<void> _loadAgents() async {
    final agents = await _manager.agents.listAgents();
    _agentReloadScheduled = false;
    if (!mounted) return;
    setState(() {
      _agentsById = {for (final agent in agents) agent.id: agent};
    });
  }

  /// Reloads agent names when the list mentions an agent we have not seen
  /// — e.g. one added in Settings after this screen was first built.
  void _ensureAgentsFor(List<Conversation> conversations) {
    if (_agentReloadScheduled) return;
    final unknown = conversations.any(
      (conversation) => !_agentsById.containsKey(conversation.primaryAgentId),
    );
    if (unknown) {
      _agentReloadScheduled = true;
      Future<void>.microtask(_loadAgents);
    }
  }

  Future<void> _startNewChat() async {
    await _loadAgents();
    if (!mounted) return;
    final agents = _agentsById.values.toList();
    if (agents.isEmpty) {
      context.go('/settings/agents');
      return;
    }
    final selected =
        await showModalBottomSheet<(SavedAgentConfig, {bool private})>(
          context: context,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Start a chat with…'),
                ),
                for (final agent in agents)
                  ListTile(
                    leading: CircleAvatar(child: Text(_initialFor(agent.name))),
                    title: Text(agent.name),
                    subtitle: agent.description.isEmpty
                        ? null
                        : Text(
                            agent.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: IconButton(
                      tooltip: 'Private chat — nothing is saved',
                      icon: const Icon(Icons.visibility_off_outlined),
                      onPressed: () =>
                          Navigator.of(context).pop((agent, private: true)),
                    ),
                    onTap: () =>
                        Navigator.of(context).pop((agent, private: false)),
                  ),
              ],
            ),
          ),
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Sized from our own constraints (not the window): the adaptive shell
    // animates slot widths, and the body must degrade gracefully while
    // space is reclaimed.
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= twoPaneBreakpoint;
      final detail = _buildDetail(embedded: wide);

      if (!wide) {
        return detail ?? _buildListPage(context);
      }

      return Row(
        children: [
          SizedBox(width: _sidebarWidth, child: _buildSidebar(context)),
          DraggableSeparator(
            onDragUpdate: (deltaX) => setState(() {
              // The floor keeps the header brand + actions on one line.
              _sidebarWidth = (_sidebarWidth + deltaX).clamp(248.0, 480.0);
            }),
          ),
          Expanded(
            child:
                detail ??
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.forum_outlined,
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
          ),
        ],
      );
    },
  );

  Widget? _buildDetail({required bool embedded}) {
    final conversationId = widget.conversationId;
    final newChatAgentId = widget.newChatAgentId;
    if (conversationId == null && newChatAgentId == null) return null;

    return FutureBuilder<SavedAgentConfig?>(
      key: ValueKey('detail-${conversationId ?? 'new-$newChatAgentId'}'),
      future: _resolveAgent(conversationId, newChatAgentId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final agent = snapshot.data;
        if (agent == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(
              child: Text('This conversation\'s agent no longer exists.'),
            ),
          );
        }
        return ChatScreen(
          key: ValueKey(conversationId ?? 'new-$newChatAgentId'),
          agent: agent,
          services: widget.services,
          conversationId: conversationId,
          embedded: embedded,
          isPrivate: conversationId == null && widget.privateChat,
          channelId: widget.channelId,
        );
      },
    );
  }

  Future<SavedAgentConfig?> _resolveAgent(
    String? conversationId,
    String? newChatAgentId,
  ) async {
    if (newChatAgentId != null) {
      return _manager.agents.getAgent(newChatAgentId);
    }
    final conversation = await _conversations.get(conversationId!);
    if (conversation == null) return null;
    // Group conversations run through their coordinator.
    return _manager.agents.getAgent(
      conversation.coordinatorAgentId ?? conversation.primaryAgentId,
    );
  }

  Future<void> _createChannel() async {
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

  /// The compact-width Chats page: app bar, list, and a new-chat FAB.
  Widget _buildListPage(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      tooltip: 'New chat',
      onPressed: _startNewChat,
      child: const Icon(Icons.add_comment_outlined),
    ),
    body: StreamBuilder<List<Channel>>(
      stream: _channelStream,
      builder: (context, channelSnapshot) => StreamBuilder<List<Conversation>>(
        stream: _conversationStream,
        builder: (context, snapshot) {
          final channels = channelSnapshot.data ?? const <Channel>[];
          final conversations = snapshot.data;
          if (conversations != null) _ensureAgentsFor(conversations);
          return CustomScrollView(
            slivers: [
              SliverAppBar.medium(
                title: const Text('Chats'),
                actions: [
                  IconButton(
                    tooltip: 'New channel',
                    icon: const Icon(Icons.tag),
                    onPressed: _createChannel,
                  ),
                ],
              ),
              if (conversations == null)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (conversations.isEmpty && channels.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(),
                )
              else
                SliverList.list(
                  children: _listChildren(context, channels, conversations),
                ),
            ],
          );
        },
      ),
    ),
  );

  /// The persistent, branded sidebar shown beside the chat on wide layouts:
  /// brand header, New Conversation button, and the chats/channels list.
  Widget _buildSidebar(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SidebarHeader(onNewChat: _startNewChat, onNewChannel: _createChannel),
        Expanded(
          child: StreamBuilder<List<Channel>>(
            stream: _channelStream,
            builder: (context, channelSnapshot) =>
                StreamBuilder<List<Conversation>>(
                  stream: _conversationStream,
                  builder: (context, snapshot) {
                    final channels = channelSnapshot.data ?? const <Channel>[];
                    final conversations = snapshot.data;
                    if (conversations == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    _ensureAgentsFor(conversations);
                    if (conversations.isEmpty && channels.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(AppSpacing.xxl),
                        child: Text(
                          'No conversations yet',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.xs,
                      ),
                      children: _listChildren(context, channels, conversations),
                    );
                  },
                ),
          ),
        ),
      ],
    ),
  );

  List<Widget> _listChildren(
    BuildContext context,
    List<Channel> channels,
    List<Conversation> conversations,
  ) => [
    if (channels.isNotEmpty) ...[
      const _SectionHeader('Channels'),
      for (final channel in channels) _channelTile(context, channel),
      const _SectionHeader('Conversations'),
    ],
    for (final conversation in conversations)
      _conversationTile(context, conversation),
  ];

  Widget _buildEmptyState() => EmptyState(
    icon: Icons.forum_outlined,
    title: 'No conversations yet',
    message:
        'Start a chat with one of your agents — they pick up right '
        'where you left off.',
    actionLabel: 'New chat',
    onAction: _startNewChat,
  );

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
    );
    if (deleted && mounted && conversation.id == widget.conversationId) {
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete channel?'),
        content: Text(
          'Delete "${channel.name}"? Its conversations are kept and stay '
          'available in Chats.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _channels.delete(channel.id);
  }

  Widget _channelTile(BuildContext context, Channel channel) => _EntryTile(
    leading: Icon(
      Icons.tag,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    title: channel.name,
    subtitle: channel.description.isEmpty ? null : channel.description,
    selected: false,
    onTap: () => context.go('/chats/channel/${channel.id}'),
    menuTooltip: 'Channel actions',
    onRename: () => unawaited(_renameChannel(channel)),
    onDelete: () => unawaited(_deleteChannel(channel)),
  );

  Widget _conversationTile(BuildContext context, Conversation conversation) {
    final agent = _agentsById[conversation.primaryAgentId];
    final selected = conversation.id == widget.conversationId;
    final title = conversation.title.trim().isEmpty
        ? (agent?.name ?? 'Untitled conversation')
        : conversation.title;
    final preview = conversation.lastMessagePreview?.trim();
    final isGroup = conversation.kind == ConversationKind.group;
    return _EntryTile(
      leading: CircleAvatar(
        radius: 14,
        child: isGroup
            ? const Icon(Icons.group_outlined, size: 16)
            : Text(
                _initialFor(agent?.name ?? title),
                style: Theme.of(context).textTheme.labelMedium,
              ),
      ),
      title: title,
      subtitle: preview == null || preview.isEmpty
          ? agent?.name
          : '${agent?.name ?? ''} • $preview',
      selected: selected,
      onTap: () => context.go('/chats/c/${conversation.id}'),
      menuTooltip: 'Conversation actions',
      onRename: () => unawaited(_renameConversation(conversation)),
      onDelete: () => unawaited(_deleteConversation(conversation)),
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
              Icon(Icons.blur_on_rounded, color: scheme.primary, size: 24),
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
                icon: const Icon(Icons.tag, size: 20),
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
            icon: const Icon(Icons.add, size: 18),
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
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String menuTooltip;
  final VoidCallback onRename;
  final VoidCallback onDelete;

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
                          fontWeight: selected
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
                PopupMenuButton<void Function()>(
                  tooltip: menuTooltip,
                  onSelected: (action) => action(),
                  icon: Icon(
                    Icons.more_horiz,
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
                          Icon(Icons.edit_outlined, size: 18),
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
                            Icons.delete_outline_rounded,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

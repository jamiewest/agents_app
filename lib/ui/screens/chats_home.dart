// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/channel_store.dart';
import '../../data/conversation_store.dart';
import '../../domain/channel.dart';
import '../../domain/conversation.dart';
import '../../main.dart' show ChatScreen;

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
  late final ChannelStore _channels;
  late final ConfiguredAgentsManager _manager;
  late final Stream<List<Conversation>> _conversationStream;
  late final Stream<List<Channel>> _channelStream;
  Map<String, SavedAgentConfig> _agentsById = const {};
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
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
        return detail ?? _buildList(context);
      }

      final listWidth = (constraints.maxWidth * 0.34).clamp(300.0, 400.0);
      return Row(
        children: [
          SizedBox(width: listWidth, child: _buildList(context)),
          const VerticalDivider(thickness: 1, width: 1),
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
                      const SizedBox(height: 12),
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

  Widget _buildList(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Chats'),
      actions: [
        IconButton(
          tooltip: 'New channel',
          icon: const Icon(Icons.tag),
          onPressed: _createChannel,
        ),
        IconButton(
          tooltip: 'New chat',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: _startNewChat,
        ),
      ],
    ),
    body: StreamBuilder<List<Channel>>(
      stream: _channelStream,
      builder: (context, channelSnapshot) => StreamBuilder<List<Conversation>>(
        stream: _conversationStream,
        builder: (context, snapshot) {
          final channels = channelSnapshot.data ?? const <Channel>[];
          final conversations = snapshot.data;
          if (conversations == null) {
            return const Center(child: CircularProgressIndicator());
          }
          _ensureAgentsFor(conversations);
          if (conversations.isEmpty && channels.isEmpty) {
            return _buildEmptyState();
          }
          return ListView(
            children: [
              if (channels.isNotEmpty) ...[
                const _SectionHeader('Channels'),
                for (final channel in channels)
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.tag)),
                    title: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: channel.description.isEmpty
                        ? null
                        : Text(
                            channel.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => context.go('/chats/channel/${channel.id}'),
                  ),
                const _SectionHeader('Conversations'),
              ],
              for (final conversation in conversations)
                _conversationTile(context, conversation),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildEmptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No conversations yet.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _startNewChat,
            icon: const Icon(Icons.add),
            label: const Text('New chat'),
          ),
        ],
      ),
    ),
  );

  Widget _conversationTile(BuildContext context, Conversation conversation) {
    final agent = _agentsById[conversation.primaryAgentId];
    final selected = conversation.id == widget.conversationId;
    final title = conversation.title.trim().isEmpty
        ? (agent?.name ?? 'Untitled conversation')
        : conversation.title;
    final preview = conversation.lastMessagePreview?.trim();
    return ListTile(
      selected: selected,
      leading: CircleAvatar(
        child: conversation.kind == ConversationKind.group
            ? const Icon(Icons.group_outlined)
            : Text(_initialFor(agent?.name ?? title)),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: preview == null || preview.isEmpty
          ? Text(agent?.name ?? '')
          : Text(
              '${agent?.name ?? ''} • $preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () => context.go('/chats/c/${conversation.id}'),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );
}

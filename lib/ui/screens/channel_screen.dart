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

/// One channel workspace: its conversations, shared files, and member
/// agents.
class ChannelScreen extends StatefulWidget {
  /// Creates a [ChannelScreen].
  const ChannelScreen({
    required this.services,
    required this.channelId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The channel to show.
  final String channelId;

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  late final RecordStore _records;
  late final ChannelStore _channels;
  late final ConversationStore _conversations;
  late final ConfiguredAgentsManager _manager;
  Channel? _channel;
  Map<String, SavedAgentConfig> _agentsById = const {};
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _records = widget.services.getRequiredService<RecordStore>();
    _channels = ChannelStore(_records);
    _conversations = ConversationStore(_records);
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    _load();
  }

  Future<void> _load() async {
    final channel = await _channels.get(widget.channelId);
    final agents = await _manager.agents.listAgents();
    if (!mounted) return;
    setState(() {
      _channel = channel;
      _agentsById = {for (final agent in agents) agent.id: agent};
    });
  }

  Future<void> _startChannelChat() async {
    final channel = _channel;
    if (channel == null) return;
    final members = [for (final id in channel.agentIds) ?_agentsById[id]];
    if (members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add an agent to the channel first (Agents tab).'),
        ),
      );
      return;
    }
    final agent = members.length == 1
        ? members.single
        : await showModalBottomSheet<SavedAgentConfig>(
            context: context,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final member in members)
                    ListTile(
                      title: Text(member.name),
                      onTap: () => Navigator.of(context).pop(member),
                    ),
                ],
              ),
            ),
          );
    if (agent != null && mounted) {
      context.go('/chats/new/${agent.id}?channel=${widget.channelId}');
    }
  }

  Future<void> _toggleMember(String agentId, bool member) async {
    final channel = _channel;
    if (channel == null) return;
    final updated = channel.copyWith(
      agentIds: member
          ? [...channel.agentIds, agentId]
          : channel.agentIds.where((id) => id != agentId).toList(),
      updatedAt: DateTime.now(),
    );
    await _channels.save(updated);
    if (mounted) setState(() => _channel = updated);
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    if (channel == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(channel.name),
          actions: [
            IconButton(
              tooltip: 'New channel chat',
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: _startChannelChat,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Conversations'),
              Tab(text: 'Files'),
              Tab(text: 'Agents'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ConversationsTab(
              conversations: _conversations.watchForChannel(channel.id),
              agentsById: _agentsById,
            ),
            _FilesTab(records: _records, channelId: channel.id),
            _AgentsTab(
              agents: _agentsById.values.toList(),
              memberIds: channel.agentIds.toSet(),
              onChanged: _toggleMember,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationsTab extends StatelessWidget {
  const _ConversationsTab({
    required this.conversations,
    required this.agentsById,
  });

  final Stream<List<Conversation>> conversations;
  final Map<String, SavedAgentConfig> agentsById;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Conversation>>(
    stream: conversations,
    builder: (context, snapshot) {
      final items = snapshot.data;
      if (items == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (items.isEmpty) {
        return const Center(child: Text('No channel conversations yet.'));
      }
      return ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final conversation = items[index];
          final agent =
              agentsById[conversation.coordinatorAgentId ??
                  conversation.primaryAgentId];
          return ListTile(
            leading: const Icon(Icons.tag),
            title: Text(
              conversation.title.trim().isEmpty
                  ? (agent?.name ?? 'Conversation')
                  : conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(agent?.name ?? ''),
            onTap: () => context.go('/chats/c/${conversation.id}'),
          );
        },
      );
    },
  );
}

class _FilesTab extends StatelessWidget {
  const _FilesTab({required this.records, required this.channelId});

  final RecordStore records;
  final String channelId;

  @override
  Widget build(BuildContext context) {
    final store = RecordStoreAgentFileStore(records, namespace: channelId);
    return FutureBuilder<List<String>>(
      future: store.listFilesAsync(''),
      builder: (context, snapshot) {
        final files = snapshot.data;
        if (files == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (files.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No shared files yet. Files written by channel agents '
                'appear here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, index) {
            final file = files[index];
            return ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(file),
              onTap: () async {
                final content = await store.readFileAsync(file);
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(file),
                    content: SingleChildScrollView(child: Text(content ?? '')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _AgentsTab extends StatelessWidget {
  const _AgentsTab({
    required this.agents,
    required this.memberIds,
    required this.onChanged,
  });

  final List<SavedAgentConfig> agents;
  final Set<String> memberIds;
  final void Function(String agentId, bool member) onChanged;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const Center(child: Text('No agents configured yet.'));
    }
    return ListView(
      children: [
        for (final agent in agents)
          CheckboxListTile(
            value: memberIds.contains(agent.id),
            title: Text(agent.name),
            subtitle: agent.description.isEmpty
                ? null
                : Text(
                    agent.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onChanged: (value) => onChanged(agent.id, value ?? false),
          ),
      ],
    );
  }
}

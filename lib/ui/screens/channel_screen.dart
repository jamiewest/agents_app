// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/channel_store.dart';
import '../../data/conversation_store.dart';
import '../../domain/channel.dart';
import '../../domain/conversation.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/empty_state.dart';
import 'chats_home.dart' show detailPaneLeading;

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

class _ChannelScreenState extends State<ChannelScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 3,
    vsync: this,
  );
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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
      // Put the user in front of the member checkboxes instead of naming
      // the tab and making them find it.
      _tabController.animateTo(2);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an agent to the channel first.')),
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

  Future<void> _renameChannel() async {
    final channel = _channel;
    if (channel == null) return;
    final name = await showRenameDialog(
      context,
      dialogTitle: 'Rename channel',
      initialTitle: channel.name,
    );
    if (name == null) return;
    final updated = channel.copyWith(name: name, updatedAt: DateTime.now());
    await _channels.save(updated);
    if (mounted) setState(() => _channel = updated);
  }

  Future<void> _deleteChannel() async {
    final channel = _channel;
    if (channel == null) return;
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
    if (mounted) context.go('/chats');
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
    // In the two-pane layout the persistent sidebar already provides
    // navigation, so the channel pane drops its redundant back button
    // (matching the embedded chat).
    final leading = detailPaneLeading(context);
    final channel = _channel;
    if (channel == null) {
      return Scaffold(
        appBar: AppBar(
          leadingWidth: leading.leadingWidth,
          leading: leading.leading,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leadingWidth: leading.leadingWidth,
        leading: leading.leading,
        title: Text(channel.name),
        actions: [
          IconButton(
            tooltip: 'New channel chat',
            icon: const Icon(Symbols.add_comment),
            onPressed: _startChannelChat,
          ),
          PopupMenuButton<void Function()>(
            tooltip: 'Channel actions',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: () => unawaited(_renameChannel()),
                child: const Text('Rename channel'),
              ),
              PopupMenuItem(
                value: () => unawaited(_deleteChannel()),
                child: const Text('Delete channel'),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Conversations'),
            Tab(text: 'Files'),
            Tab(text: 'Agents'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
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
        return const EmptyState(
          icon: Symbols.tag,
          title: 'No channel conversations yet',
          message: 'Start one with a member agent using the button above.',
        );
      }
      return ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final conversation = items[index];
          final agent =
              agentsById[conversation.coordinatorAgentId ??
                  conversation.primaryAgentId];
          return ListTile(
            leading: const Icon(Symbols.tag),
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

class _FilesTab extends StatefulWidget {
  const _FilesTab({required this.records, required this.channelId});

  final RecordStore records;
  final String channelId;

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  late final RecordStoreAgentFileStore _store;
  late Future<List<String>> _files;

  @override
  void initState() {
    super.initState();
    _store = RecordStoreAgentFileStore(
      widget.records,
      namespace: widget.channelId,
    );
    _files = _store.listFilesAsync('');
  }

  void _refresh() => setState(() => _files = _store.listFilesAsync(''));

  /// Uploads a text file into the channel's shared workspace, where every
  /// channel agent can read it.
  Future<void> _upload() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Text',
          extensions: ['txt', 'md', 'csv', 'json', 'yaml', 'xml'],
        ),
      ],
    );
    if (picked == null) return;
    try {
      final content = await picked.readAsString();
      await _store.writeFileAsync(picked.name, content);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read that file as text. ($e)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploadButton = Padding(
      padding: const EdgeInsets.all(12),
      child: OutlinedButton.icon(
        onPressed: _upload,
        icon: const Icon(Symbols.upload_file),
        label: const Text('Upload text file'),
      ),
    );
    return FutureBuilder<List<String>>(
      future: _files,
      builder: (context, snapshot) {
        final files = snapshot.data;
        if (files == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            uploadButton,
            Expanded(
              child: files.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No shared files yet. Upload one, or let channel '
                          'agents write them.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (context, index) =>
                          _fileTile(context, files[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _fileTile(BuildContext context, String file) => ListTile(
    leading: const Icon(Symbols.description),
    title: Text(file),
    onTap: () async {
      final content = await _store.readFileAsync(file);
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

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents/agents.dart' show AIAgent, AgentSession;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_flutter/chat_provider.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/chat_transcript_mapping.dart';
import '../../features/local_models/local_llama_progress_banner.dart';
import '../widgets/agent_start_error.dart';
import '../widgets/chat_menu_label.dart';
import '../../chat_toolkit/views/llm_chat_view/llm_chat_view.dart';
import '../widgets/chat_terminal_panel.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/prompt_inspector_panel.dart';
import '../widgets/usage_stats_sheet.dart';
import 'chats_home.dart' show detailPaneLeading;

/// Resolves a saved agent and shows a chat against it.
class ChatScreen extends StatefulWidget {
  /// Creates a [ChatScreen].
  const ChatScreen({
    required this.agent,
    required this.services,
    this.conversationId,
    this.embedded = false,
    this.isPrivate = false,
    this.channelId,
    super.key,
  });

  /// The saved agent to chat with.
  final SavedAgentConfig agent;

  /// The application service provider.
  final ServiceProvider services;

  /// The conversation to resume, or `null` to start a blank conversation.
  final String? conversationId;

  /// Whether this screen renders inside a two-pane layout rather than as a
  /// pushed route. Embedded screens show no back button and do not
  /// intercept pops; state still flushes on dispose.
  final bool embedded;

  /// Whether this is a private conversation: nothing is persisted — no
  /// conversation record, no session state, no transcript.
  final bool isPrivate;

  /// The channel a NEW conversation should belong to, when starting one
  /// from a channel. Resumed conversations keep their stored channel.
  final String? channelId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late Future<AgentLlmProvider> _providerFuture;
  bool _initialized = false;
  AgentLlmProvider? _provider;
  ConversationStore? _conversations;
  ConversationSessionStore? _sessions;
  ChatTranscriptStore? _transcripts;
  UsageStore? _usage;
  Conversation? _existingConversation;
  ModelConfig? _model;
  bool _supportsImageAttachments = true;
  bool _isNetworkAgent = false;
  Future<void> _networkTranscriptWrite = Future<void>.value();
  List<ConversationSession> _sessionList = const [];
  String? _viewSessionId;
  late String _conversationId;
  late String _sessionId;
  DateTime? _sessionStartedAt;
  bool _conversationExists = false;
  String _title = '';
  ConversationTitleSource _titleSource = ConversationTitleSource.none;
  DateTime? _createdAt;
  Future<void> _pendingPersistence = Future<void>.value();
  bool _isPopping = false;
  bool _deleted = false;
  StreamSubscription<String>? _agentChangesSub;
  Set<String> _relevantAgentIds = const {};
  bool _agentReloadScheduled = false;
  bool _agentReloadInProgress = false;
  int _toolActivityRefs = 0;
  ChatTerminalSession? _terminalSession;

  /// Acquires this conversation's terminal session once, so the chat body
  /// can dock a live terminal over the agent's shell commands. Released in
  /// [dispose]; agent reloads reuse the same session, keeping the buffer.
  ChatTerminalSession? _listenTerminalSession() => _terminalSession ??= widget
      .services
      .getService<TerminalActivity>()
      ?.listen(_conversationId);

  /// Acquires this conversation's tool-activity channel, when the registry
  /// is registered. Every acquisition is matched by [_releaseToolActivity];
  /// the last release (in [dispose]) drops the channel.
  ValueListenable<String?>? _listenToolActivity() {
    final registry = widget.services.getService<ToolActivity>();
    if (registry == null) return null;
    _toolActivityRefs++;
    return registry.listen(_conversationId);
  }

  void _releaseToolActivity() {
    if (_toolActivityRefs == 0) return;
    _toolActivityRefs--;
    widget.services.getService<ToolActivity>()?.release(_conversationId);
  }

  @override
  void initState() {
    super.initState();
    // Rebuild the live agent when the configuration behind this chat (or one
    // of its delegates/participants) is edited, so changes to model,
    // instructions, or tool access apply without leaving the conversation.
    _agentChangesSub = widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agentChanges
        .listen(_onAgentConfigChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
    _sessions = ConversationSessionStore(records);
    _transcripts = ChatTranscriptStore(records);
    _usage = UsageStore(records);
    _providerFuture = _createProvider(
      widget.services.getRequiredService<ConfiguredAgentFactory>(),
    );
  }

  Future<AgentLlmProvider> _createProvider(
    ConfiguredAgentFactory factory,
  ) async {
    final conversations = _conversations!;
    final conversationId = widget.conversationId;
    final record = conversationId == null
        ? null
        : await conversations.get(conversationId);
    _existingConversation = record;
    _conversationId =
        record?.id ?? conversationId ?? conversations.newConversationId();
    _conversationExists = record != null;
    _title = record?.title ?? '';
    _titleSource = record?.titleSource ?? ConversationTitleSource.none;
    _createdAt = record?.createdAt;

    // Opening a conversation clears its unread marker (set by a background
    // task run). copyWith preserves updatedAt, so reading a chat never
    // reorders the chats list.
    if (record != null && record.hasUnread) {
      _existingConversation = record.copyWith(hasUnread: false);
      unawaited(conversations.save(_existingConversation!));
    }

    // Group conversations run through the coordinator with the other
    // participants attached as background agents.
    final extraDelegations = <AgentDelegationConfig>[
      if (record != null && record.kind == ConversationKind.group)
        for (final participantId in record.participantAgentIds)
          if (participantId != widget.agent.id)
            AgentDelegationConfig(agentId: participantId),
    ];
    _relevantAgentIds = _computeRelevantAgentIds(widget.agent, record);

    final modelSources = widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .sources;
    _model = await modelSources.getModel(widget.agent.modelId);
    final modelSource = _model == null
        ? null
        : await modelSources.getSource(_model!.sourceId);
    // Cloud providers are multimodal; a local model can only look at images
    // when its configuration advertises vision (a projector is bundled).
    _supportsImageAttachments =
        modelSource?.providerType != ProviderType.localLlama ||
        _model!.capabilities.supportsVision;
    // Remote (A2A) agents run inside the host's harness and so bypass the
    // local durable chat-history provider; the app persists their display
    // transcript itself (see [_persistNetworkTranscript]).
    _isNetworkAgent = modelSource?.providerType == ProviderType.network;

    final sessionList = widget.isPrivate
        ? const <ConversationSession>[]
        : await _sessions!.listFor(_conversationId);
    _sessionList = sessionList;
    final latestSession = sessionList.isEmpty ? null : sessionList.last;
    _sessionId = latestSession?.id ?? _sessions!.newSessionId();
    _sessionStartedAt = latestSession?.startedAt;

    // The scope routes the agent's chat history through the durable
    // transcript, so the model resumes with full-fidelity context and no
    // replay step. Private scopes keep the default in-memory history.
    // An AgentRunScope stamps each usage record with the agent and the turn
    // in flight, so tokens can be rolled up per agent and joined back to a
    // run. The run id is resolved lazily through the provider because one
    // scope serves every turn of this conversation, and the provider does
    // not exist yet.
    final agent = await factory.createAgent(
      widget.agent,
      scope: AgentRunScope(
        conversationId: _conversationId,
        sessionIdResolver: () => _sessionId,
        agentId: widget.agent.id,
        runIdResolver: () => _provider?.currentRunId,
        isPrivate: widget.isPrivate,
        channelId: record?.channelId ?? widget.channelId,
      ),
      extraDelegations: extraDelegations,
    );
    final serialized = latestSession?.serializedAgentSession;
    final session = serialized != null
        ? await agent.deserializeSession(serialized)
        : await agent.createSession();

    final displayHistory = await _loadDisplayHistory();

    final provider = AgentLlmProvider(
      agent: agent,
      session: session,
      toolActivity: _listenToolActivity(),
      activity: widget.services.getService<AppActivityMonitor>(),
      // Private conversations publish live status but persist no run
      // history, matching the usage ledger's existing rule.
      runs: widget.isPrivate
          ? null
          : widget.services.getService<AgentRunTelemetryStore>(),
      beginRun: (runs) => _beginRun(runs, widget.agent),
      history: displayHistory,
    );
    // Attach after restore so persistence reflects ongoing turns only.
    provider.addListener(() {
      _pendingPersistence = _persistMetadata(provider);
    });
    _provider = provider;
    _refreshTitle();
    return provider;
  }

  /// Opens a run record for a turn, snapshotting the agent, model, and
  /// source labels as they read right now.
  ///
  /// The labels are copied rather than referenced so a run stays readable
  /// after the agent is renamed or the model deleted.
  Future<AgentRunHandle> _beginRun(
    AgentRunTelemetryStore runs,
    SavedAgentConfig agent,
  ) async {
    final manager = widget.services.getService<ConfiguredAgentsManager>();
    final model = await manager?.sources.getModel(agent.modelId);
    final source = model == null
        ? null
        : await manager?.sources.getSource(model.sourceId);
    return runs.begin(
      agentId: agent.id,
      agentName: agent.name,
      origin: AgentRunOrigin.chat,
      modelId: model?.id ?? agent.modelId,
      modelName: model?.label,
      sourceId: source?.id,
      sourceName: source?.displayName,
      conversationId: _conversationId,
    );
  }

  /// The set of configured-agent ids whose edits should refresh this chat:
  /// the agent itself, its saved delegates, and (for group conversations)
  /// the other participants.
  Set<String> _computeRelevantAgentIds(
    SavedAgentConfig agent,
    Conversation? record,
  ) => {
    agent.id,
    for (final delegation in agent.delegations) delegation.agentId,
    if (record != null && record.kind == ConversationKind.group)
      ...record.participantAgentIds,
  };

  void _onAgentConfigChanged(String agentId) {
    if (!mounted || !_relevantAgentIds.contains(agentId)) return;
    _scheduleAgentReload();
  }

  /// Rebuilds the live agent, deferring until any in-flight turn settles so a
  /// streaming response is not torn off mid-reply.
  void _scheduleAgentReload() {
    if (_agentReloadScheduled) return;
    final provider = _provider;
    if (provider == null) return;
    _agentReloadScheduled = true;
    // A reload is already running; its finally clause re-triggers once the
    // freshly swapped provider is in place, so don't touch the old one.
    if (_agentReloadInProgress) return;
    if (!provider.isBusy) {
      unawaited(_reloadAgent());
      return;
    }
    void onSettled() {
      if (provider.isBusy) return;
      provider.removeListener(onSettled);
      unawaited(_reloadAgent());
    }

    provider.addListener(onSettled);
  }

  /// Rebuilds the agent from its current saved configuration, carrying the
  /// running session and display history onto the new instance so the
  /// conversation continues unbroken.
  Future<void> _reloadAgent() async {
    _agentReloadScheduled = false;
    // Guard against a second change arriving mid-rebuild and racing a
    // concurrent reload onto the same session (double-dispose, leaked
    // provider). Re-run once the in-flight reload finishes.
    if (_agentReloadInProgress) {
      _agentReloadScheduled = true;
      return;
    }
    final old = _provider;
    if (old == null || !mounted) return;
    _agentReloadInProgress = true;

    try {
      await _pendingPersistence;
      final manager = widget.services
          .getRequiredService<ConfiguredAgentsManager>();
      final factory = widget.services
          .getRequiredService<ConfiguredAgentFactory>();
      final config = await manager.agents.getAgent(widget.agent.id);
      // The agent was deleted out from under the chat; leave the current
      // instance in place rather than tearing the conversation down.
      if (config == null || !mounted) return;

      final record = _existingConversation;
      _relevantAgentIds = _computeRelevantAgentIds(config, record);

      final modelSources = manager.sources;
      _model = await modelSources.getModel(config.modelId);
      final modelSource = _model == null
          ? null
          : await modelSources.getSource(_model!.sourceId);
      _supportsImageAttachments =
          modelSource?.providerType != ProviderType.localLlama ||
          _model!.capabilities.supportsVision;
      _isNetworkAgent = modelSource?.providerType == ProviderType.network;

      final extraDelegations = <AgentDelegationConfig>[
        if (record != null && record.kind == ConversationKind.group)
          for (final participantId in record.participantAgentIds)
            if (participantId != config.id)
              AgentDelegationConfig(agentId: participantId),
      ];

      final agent = await factory.createAgent(
        config,
        scope: AgentRunScope(
          conversationId: _conversationId,
          sessionIdResolver: () => _sessionId,
          agentId: config.id,
          runIdResolver: () => _provider?.currentRunId,
          isPrivate: widget.isPrivate,
          channelId: record?.channelId ?? widget.channelId,
        ),
        extraDelegations: extraDelegations,
      );

      // Reuse the live session state so the rebuilt agent resumes with the
      // full in-memory context, not just what has been persisted. The saved
      // session was produced by an agent with a different provider/tool set;
      // if deserializing it onto the rebuilt agent fails (e.g. a context
      // provider was disabled), start a fresh session rather than aborting
      // the swap — for persisted chats the history provider restores context
      // anyway, so the tool change still lands.
      final serialized = old.session == null
          ? null
          : await _serializeSession(old.agent, old.session!);
      AgentSession session;
      try {
        session = serialized != null
            ? await agent.deserializeSession(serialized)
            : await agent.createSession();
      } catch (e, s) {
        developer.log(
          'Could not carry the session across an agent reload; '
          'starting a fresh one.',
          name: 'agents_app.chat_sessions',
          error: e,
          stackTrace: s,
        );
        session = await agent.createSession();
      }

      if (!mounted) return;
      final provider = AgentLlmProvider(
        agent: agent,
        session: session,
        // Acquired before the old provider's ref is released below, so the
        // conversation's channel stays alive across the swap.
        toolActivity: _listenToolActivity(),
        // Match initial construction: without the idle monitor, background
        // work (e.g. the title summarizer) could run mid-generation after
        // a reload.
        activity: widget.services.getService<AppActivityMonitor>(),
        history: old.history,
      );
      provider.addListener(() {
        _pendingPersistence = _persistMetadata(provider);
      });

      _provider = provider;
      setState(() {
        _providerFuture = Future<AgentLlmProvider>.value(provider);
      });
      old.dispose();
      _releaseToolActivity();
    } catch (e, s) {
      developer.log(
        'Failed to reload agent after a configuration change.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    } finally {
      _agentReloadInProgress = false;
      // A change that arrived mid-rebuild left a request queued; honor it now
      // against the freshly swapped provider.
      if (_agentReloadScheduled && mounted) {
        _agentReloadScheduled = false;
        _scheduleAgentReload();
      }
    }
  }

  /// Loads this conversation's durable transcript as displayable messages.
  ///
  /// The transcript-to-display mapping itself lives in
  /// `data/chat_transcript_mapping.dart`, which is pure and unit-tested.
  Future<List<ChatMessage>> _loadDisplayHistory({String? sessionId}) async =>
      displayMessagesFrom(
        await _transcripts!.load(_conversationId),
        sessionId: sessionId,
      );

  /// Persists conversation metadata and the serialized agent session.
  ///
  /// The transcript itself is written by the agent's chat history provider
  /// during invocation; this only maintains the list-view record.
  Future<void> _persistMetadata(AgentLlmProvider provider) async {
    if (widget.isPrivate) return;
    try {
      final history = provider.history.toList();
      if (history.isEmpty) return;

      final now = DateTime.now();
      _createdAt ??= now;
      _setDefaultTitleFrom(history);
      await _adoptBackgroundTitle();

      String? preview;
      for (final message in history.reversed) {
        final text = message.text?.trim();
        if (text != null && text.isNotEmpty) {
          preview = text;
          break;
        }
      }

      final existing = _existingConversation;
      await _conversations!.save(
        Conversation(
          id: _conversationId,
          kind: existing?.kind ?? ConversationKind.direct,
          title: _title,
          titleSource: _titleSource,
          participantAgentIds:
              existing?.participantAgentIds ?? [widget.agent.id],
          coordinatorAgentId: existing?.coordinatorAgentId,
          channelId: existing?.channelId ?? widget.channelId,
          createdAt: _createdAt!,
          updatedAt: now,
          lastMessagePreview: preview,
          // This only runs from the open ChatScreen on an active turn, so the
          // conversation is being viewed: never carry an unread marker here.
        ),
      );
      _conversationExists = true;

      unawaited(_persistSerializedSession(provider));
      // Awaited so the pop/dispose flush (which awaits [_pendingPersistence])
      // sees the final turn's transcript land before the screen tears down.
      await _persistNetworkTranscript(provider);
    } catch (e, s) {
      developer.log(
        'Failed to persist conversation metadata.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _persistSubmittedPrompt(
    AgentLlmProvider provider,
    String prompt,
    Iterable<Attachment> attachments,
  ) async {
    final text = prompt.trim();
    if (text.isEmpty) return;

    final augmented = AgentLlmProvider(
      agent: provider.agent,
      session: provider.session,
      history: [...provider.history, ChatMessage.user(prompt, attachments)],
    );
    try {
      await _persistMetadata(augmented);
    } finally {
      augmented.dispose();
    }
  }

  Future<void> _persistSerializedSession(AgentLlmProvider provider) async {
    if (widget.isPrivate) return;
    try {
      final serializedSession = await _serializeSession(
        provider.agent,
        provider.session!,
      );
      if (serializedSession == null) return;

      await _sessions!.save(
        ConversationSession(
          id: _sessionId,
          conversationId: _conversationId,
          startedAt: _sessionStartedAt ??= DateTime.now(),
          serializedAgentSession: serializedSession,
        ),
      );
    } catch (e, s) {
      developer.log(
        'Failed to update persisted session state.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    }
  }

  /// Rewrites the display transcript for a remote (A2A) conversation.
  ///
  /// Remote agents run inside the paired host's harness, so their turns never
  /// reach the local [FlutterChatHistoryProvider] that writes the durable
  /// transcript for local agents. Without this a networked conversation
  /// reopens blank even though its metadata and session pointer were saved.
  ///
  /// The change listener fires on every streamed chunk, so this waits until
  /// the turn has settled ([AgentLlmProvider.isBusy] is false) and then does a
  /// full idempotent replace from the live UI history — never a per-chunk
  /// append, which would multiply stored bubbles. Writes are serialized
  /// through [_networkTranscriptWrite] because a replace is delete-then-write
  /// and the listener can fire more than once around a turn.
  Future<void> _persistNetworkTranscript(AgentLlmProvider provider) {
    // A filtered session view swaps a partial slice into [provider.history];
    // rewriting the whole transcript from it would drop the other sessions.
    // Network chats are kept single-session (see the conversation-actions
    // menu), so this only guards against a future caller reintroducing one.
    if (widget.isPrivate ||
        !_isNetworkAgent ||
        provider.isBusy ||
        _viewSessionId != null) {
      return Future<void>.value();
    }
    final messages = transcriptMessagesFrom(provider.history);
    final write = _networkTranscriptWrite.then((_) async {
      try {
        await _transcripts!.replace(
          conversationId: _conversationId,
          sessionId: _sessionId,
          messages: messages,
          senderAgentId: widget.agent.id,
        );
      } catch (e, s) {
        developer.log(
          'Failed to persist networked conversation transcript.',
          name: 'agents_app.chat_sessions',
          error: e,
          stackTrace: s,
        );
      }
    });
    _networkTranscriptWrite = write;
    return write;
  }

  Future<void> _discardEmptyConversation() async {
    final provider = _provider;
    if (provider == null || _conversationExists) return;
    if (provider.history.isNotEmpty) return;

    try {
      final entries = await _transcripts!.load(_conversationId);
      if (entries.isNotEmpty) return;
      await _sessions!.deleteFor(_conversationId);
      await _conversations!.delete(_conversationId);
    } catch (e, s) {
      developer.log(
        'Failed to discard empty conversation.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<String?> _serializeSession(AIAgent agent, AgentSession session) async {
    try {
      final serialized = await agent.serializeSession(session);
      return serialized is String ? serialized : null;
    } catch (e, s) {
      developer.log(
        'Failed to serialize chat session.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  /// Starts a NEW group conversation with this agent as coordinator plus a
  /// chosen teammate; the current conversation is left untouched.
  Future<void> _addAgentToChat() async {
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final agents = await manager.agents.listAgents();
    final existing = _existingConversation;
    final participantIds = existing?.participantAgentIds ?? [widget.agent.id];
    final candidates = agents
        .where((agent) => !participantIds.contains(agent.id))
        .toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other agents to add yet.')),
      );
      return;
    }

    final added = await showModalBottomSheet<SavedAgentConfig>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Start a group chat with… (this conversation stays as is)',
              ),
            ),
            for (final candidate in candidates)
              ListTile(
                title: Text(candidate.name),
                subtitle: candidate.description.isEmpty
                    ? null
                    : Text(
                        candidate.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => Navigator.of(context).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (added == null || !mounted) return;

    // Any participant could coordinate, but asking the user to pick one
    // exposes an internal concept; the current agent is always a sound
    // default, so use it without a dialog.
    final coordinator = widget.agent;

    final original =
        existing ??
        Conversation(
          id: _conversationId,
          kind: ConversationKind.direct,
          title: _title,
          titleSource: _titleSource,
          participantAgentIds: [widget.agent.id],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
    final group = await ConversationService(_conversations!)
        .createGroupFromDirect(
          original: original,
          addedAgentIds: [added.id],
          coordinatorAgentId: coordinator.id,
          agentNamesById: {for (final agent in agents) agent.id: agent.name},
        );
    if (mounted) context.go('/chats/c/${group.id}');
  }

  Future<void> _refreshSessionList() async {
    if (widget.isPrivate) return;
    _sessionList = await _sessions!.listFor(_conversationId);
    if (mounted) setState(() {});
  }

  /// Shows one session's slice of the transcript, or the stitched whole.
  ///
  /// Display only: the model always receives the full stitched history
  /// through its chat history provider.
  Future<void> _viewSession(String? sessionId) async {
    final provider = _provider;
    if (provider == null) return;
    _viewSessionId = sessionId;
    provider.history = await _loadDisplayHistory(sessionId: sessionId);
    if (mounted) setState(() {});
  }

  Future<void> _toggleThinking(String modelConfigId) async {
    final settings = widget.services.getRequiredService<ThinkingSettings>();
    await settings.setEnabled(
      modelConfigId,
      !settings.enabledFor(modelConfigId),
    );
    if (mounted) setState(() {});
  }

  /// Ends the current session and starts a fresh one.
  ///
  /// The conversation and its transcript continue (stitched display and
  /// model context are conversation-scoped); only the session epoch — the
  /// serialized agent-session state new turns are stamped with — resets.
  Future<void> _startNewSession() async {
    final provider = _provider;
    // Network chats are single-session: their transcript is rewritten whole
    // from the live history, so a second session epoch would strand the
    // earlier turns. The menu hides this action for them; guard it anyway.
    if (provider == null || _isNetworkAgent) return;
    await _pendingPersistence;

    final endedAt = DateTime.now();
    final previous = await _sessions!.latestFor(_conversationId);
    if (previous != null && previous.id == _sessionId) {
      await _sessions!.save(previous.copyWith(endedAt: endedAt));
    }
    setState(() {
      _sessionId = _sessions!.newSessionId();
      _sessionStartedAt = null;
    });
    await _refreshSessionList();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Started a new session.')));
    }
  }

  Future<void> _renameConversation() async {
    final provider = _provider;
    if (provider == null) return;

    final title = await showRenameDialog(
      context,
      dialogTitle: 'Rename conversation',
      initialTitle: _title,
    );
    if (title == null) return;

    setState(() {
      _title = title;
      _titleSource = ConversationTitleSource.manual;
    });
    _pendingPersistence = _persistMetadata(provider);
    await _pendingPersistence;
  }

  /// Deletes this conversation (with confirmation) and leaves the chat.
  Future<void> _deleteConversation() async {
    if (_provider == null) return;
    final deleted = await confirmAndDeleteConversation(
      context,
      conversationId: _conversationId,
      title: _appBarTitle,
      conversations: _conversations!,
      sessions: _sessions!,
      transcripts: _transcripts!,
      usage: _usage,
    );
    if (!deleted) return;
    _deleted = true;
    if (mounted) context.go('/chats');
  }

  /// Adopts a title the background summarizer (or a rename elsewhere) wrote
  /// underneath us, instead of overwriting it with the auto-derived one.
  Future<void> _adoptBackgroundTitle() async {
    if (_titleSource != ConversationTitleSource.firstMessage &&
        _titleSource != ConversationTitleSource.none) {
      return;
    }
    final stored = await _conversations!.get(_conversationId);
    if (stored == null) return;
    if (stored.titleSource == ConversationTitleSource.summary ||
        stored.titleSource == ConversationTitleSource.manual) {
      _title = stored.title;
      _titleSource = stored.titleSource;
      _refreshTitle();
    }
  }

  void _setDefaultTitleFrom(List<ChatMessage> history) {
    if (_titleSource != ConversationTitleSource.none) return;
    for (final message in history) {
      if (!message.origin.isUser) continue;
      final text = message.text?.trim();
      if (text == null || text.isEmpty) continue;
      _title = truncateConversationTitle(text);
      _titleSource = ConversationTitleSource.firstMessage;
      _refreshTitle();
      return;
    }
  }

  void _refreshTitle() {
    if (mounted) setState(() {});
  }

  String get _appBarTitle {
    final title = _title.trim();
    return title.isEmpty ? widget.agent.name : title;
  }

  Future<void> _finishStateChangesBeforePop() async {
    // A deleted conversation must stay deleted: flushing here would
    // re-save its metadata and resurrect the record.
    if (_deleted) return;
    await _pendingPersistence;
    await _flushLatestConversationState();
    await _discardEmptyConversation();
  }

  Future<void> _flushLatestConversationState() async {
    final provider = _provider;
    if (provider == null ||
        provider.session == null ||
        provider.history.isEmpty) {
      return;
    }

    _pendingPersistence = _persistMetadata(provider);
    await _pendingPersistence;
  }

  Future<void> _handlePop() async {
    if (_isPopping) return;
    _isPopping = true;
    await _finishStateChangesBeforePop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    unawaited(_agentChangesSub?.cancel());
    unawaited(_finishStateChangesBeforePop());
    _provider?.dispose();
    while (_toolActivityRefs > 0) {
      _releaseToolActivity();
    }
    if (_terminalSession != null) {
      _terminalSession = null;
      // Non-null session implies _conversationId was initialized.
      widget.services.getService<TerminalActivity>()?.release(_conversationId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leading = detailPaneLeading(context);
    return PopScope<void>(
      canPop: widget.embedded,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handlePop());
      },
      child: _buildChatScaffold(context, leading),
    );
  }

  Widget _buildChatScaffold(
    BuildContext context,
    ({Widget? leading, double? leadingWidth, double? titleSpacing}) leading,
  ) => Scaffold(
    appBar: AppBar(
      // Match the LlmChatView body (scheme.surface) so the chat window
      // reads as one continuous surface rather than a banded app bar.
      backgroundColor: Theme.of(context).colorScheme.surface,
      leadingWidth: leading.leadingWidth,
      leading: leading.leading,
      titleSpacing: leading.titleSpacing,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isPrivate) ...[
            Tooltip(
              message: 'Private chat — nothing is saved',
              child: Icon(
                LucideIcons.eyeOff300,
                size: 18,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(_appBarTitle, overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: [
        Builder(
          builder: (context) {
            final log = widget.services.getService<PromptLog>();
            final usage = widget.isPrivate ? null : _usage;
            final thinkingModel = switch (_model) {
              final model? when model.capabilities.supportsThinking => model,
              _ => null,
            };
            final hasSessionPicker =
                !widget.isPrivate &&
                !_isNetworkAgent &&
                _sessionList.length > 1;
            final hasUtilityItems =
                thinkingModel != null || log != null || usage != null;
            final hasMenu =
                !widget.isPrivate || hasUtilityItems || hasSessionPicker;
            if (!hasMenu) return const SizedBox.shrink();

            return PopupMenuButton<void Function()>(
              tooltip: 'Conversation actions',
              icon: const Icon(LucideIcons.ellipsis300),
              onSelected: (action) => action(),
              itemBuilder: (_) => [
                if (thinkingModel case final model?)
                  PopupMenuItem(
                    value: () => unawaited(_toggleThinking(model.id)),
                    child: ChatMenuLabel(
                      icon: LucideIcons.brain300,
                      label: 'Thinking',
                      selected: widget.services
                          .getRequiredService<ThinkingSettings>()
                          .enabledFor(model.id),
                    ),
                  ),
                if (log != null)
                  PopupMenuItem(
                    value: () => unawaited(showPromptInspector(context, log)),
                    child: const ChatMenuLabel(
                      icon: LucideIcons.braces300,
                      label: 'Inspect',
                    ),
                  ),
                if (usage != null)
                  PopupMenuItem(
                    value: () => unawaited(
                      showUsageStats(
                        context,
                        usage: usage,
                        conversationId: _conversationId,
                        currentSessionId: _sessionId,
                      ),
                    ),
                    child: const ChatMenuLabel(
                      icon: LucideIcons.chartPie300,
                      label: 'Usage',
                    ),
                  ),
                // Network chats stay single-session (their transcript is
                // rewritten whole from live history), so the per-session
                // view never applies.
                if (hasSessionPicker) ...[
                  if (hasUtilityItems) const PopupMenuDivider(),
                  const PopupMenuItem(
                    enabled: false,
                    child: ChatMenuLabel(
                      icon: LucideIcons.history300,
                      label: 'Sessions',
                    ),
                  ),
                  CheckedPopupMenuItem(
                    value: () => unawaited(_viewSession(null)),
                    checked: _viewSessionId == null,
                    child: const Text('All sessions (stitched)'),
                  ),
                  for (final session in _sessionList)
                    CheckedPopupMenuItem(
                      value: () => unawaited(_viewSession(session.id)),
                      checked: _viewSessionId == session.id,
                      child: Text(
                        '${formatConversationDate(session.startedAt)}'
                        '${session.id == _sessionId ? ' • current' : ''}',
                      ),
                    ),
                ],
                if (!widget.isPrivate) ...[
                  if (hasUtilityItems || hasSessionPicker)
                    const PopupMenuDivider(),
                  // A new session re-stamps only new turns for local agents,
                  // but a network chat rewrites its whole transcript under
                  // one session, so segmenting it would strand earlier turns.
                  if (!_isNetworkAgent)
                    PopupMenuItem(
                      enabled: _provider != null,
                      value: () => unawaited(_startNewSession()),
                      child: const Text('New session'),
                    ),
                  PopupMenuItem(
                    enabled: _provider != null,
                    value: () => unawaited(_addAgentToChat()),
                    child: const Text('Start group chat…'),
                  ),
                  PopupMenuItem(
                    enabled: _provider != null,
                    value: () => unawaited(_renameConversation()),
                    child: const Text('Rename'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    enabled: _provider != null,
                    value: () => unawaited(_deleteConversation()),
                    child: const Text('Delete conversation'),
                  ),
                ],
              ],
            );
          },
        ),
        SizedBox(width: 12),
      ],
    ),
    body: _buildChatBody(context),
  );

  Widget _buildChatBody(BuildContext context) =>
      FutureBuilder<AgentLlmProvider>(
        future: _providerFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return AgentStartError(
              error: snapshot.error!,
              onRetry: () => setState(() {
                _providerFuture = _createProvider(
                  widget.services.getRequiredService<ConfiguredAgentFactory>(),
                );
              }),
            );
          }
          final provider = snapshot.data;
          if (provider == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final terminalSession = _listenTerminalSession();
          return Column(
            children: [
              LocalLlamaProgressBanner(modelId: widget.agent.modelId),
              Expanded(
                child: LlmChatView(
                  provider: provider,
                  onMessageSubmitted: (prompt, {required attachments}) =>
                      _persistSubmittedPrompt(provider, prompt, attachments),
                  welcomeMessage: 'Ask ${widget.agent.name} anything.',
                  dock: terminalSession == null
                      ? null
                      : ChatTerminalPanel(session: terminalSession),
                  enableAttachments: true,
                  enableImageAttachments: _supportsImageAttachments,
                  enableVoiceNotes: false,
                ),
              ),
            ],
          );
        },
      );
}

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents/agents.dart'
    show
        AIAgent,
        AgentSession,
        ChatHistoryMemoryProvider,
        ChatHistoryMemoryProviderScope,
        ChatHistoryMemoryProviderState;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_llama/agents_llama.dart' as llama;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'data/chat_transcript_store.dart';
import 'data/conversation_service.dart';
import 'data/conversation_store.dart';
import 'data/embedding_settings.dart';
import 'data/task_scheduler_service.dart';
import 'data/theme_settings.dart';
import 'data/thinking_settings.dart';
import 'domain/conversation.dart';
import 'navigation/app_bootstrap.dart';
import 'navigation/app_router.dart';
import 'ui/app_theme.dart';
import 'ui/providers/providers.dart';
import 'ui/views/configured_agents/configured_agents.dart';
import 'ui/views/llm_chat_view/llm_chat_view.dart';
import 'ui/widgets/conversation_actions.dart';

// Optional seed values so the demo can start with a working Anthropic agent.
// Supply them as compile-time defines, e.g.
//   flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-...
// They are only used to pre-populate the runtime configuration on first launch;
// thereafter sources, models, and agents are managed entirely in the UI.
const _seedApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const _seedModel = String.fromEnvironment(
  'ANTHROPIC_MODEL',
  defaultValue: 'claude-haiku-4-5-20251001',
);

// This is how we build and run the application, dont stray.
// <start>
final _builder = Host.createApplicationBuilder()
  ..logging.setMinimumLevel(LogLevel.trace)
  ..services.addFlutter((flutter) {
    flutter.services.addDownloadService();
    flutter.services.addRecordStore();
    flutter.services.tryAddSingleton<ThemeSettings>(
      (sp) => ThemeSettings(sp.getRequiredService<KeyValueStore>()),
    );
    flutter.services.tryAddSingleton<ThinkingSettings>(
      (sp) => ThinkingSettings(sp.getRequiredService<KeyValueStore>()),
    );
    flutter.services.tryAddSingleton<EmbeddingSettings>(
      (sp) => EmbeddingSettings(
        keyValueStore: sp.getRequiredService<KeyValueStore>(),
        manager: sp.getRequiredService<ConfiguredAgentsManager>(),
      ),
    );
    flutter.useFlutterHarnessAgent();
    flutter.useConfiguredAgents(
      chatClientFactory: (sp) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            _createLocalLlamaClient(sp, source: source, model: model),
      ),
      configureHarnessForScope: (sp) => (agent, options, scope) {
        // Private conversations keep the default in-memory capabilities;
        // durable ones read and write conversation-scoped persistence, so
        // resumed chats need no replay step.
        if (scope.isPrivate) return;
        final records = sp.getRequiredService<RecordStore>();
        options.chatHistoryProvider = FlutterChatHistoryProvider(
          records,
          conversationId: scope.conversationId,
          sessionIdResolver: scope.sessionIdResolver,
          senderAgentId: agent.id,
        );

        // Agent-written files persist per conversation (or channel).
        final namespace = scope.channelId ?? scope.conversationId;
        options.fileAccessStore = RecordStoreAgentFileStore(
          records,
          namespace: namespace,
        );
        options.fileMemoryStore = RecordStoreAgentFileStore(
          records,
          namespace: '$namespace#memory',
        );

        // Long-term memory: whole-conversation recall through the vector
        // store, scoped so agents never see each other's memories.
        options.aiContextProviders = [
          ...?options.aiContextProviders,
          ChatHistoryMemoryProvider(
            RecordStoreVectorStore(
              records,
              scorer: sp.getRequiredService<EmbeddingSettings>(),
            ),
            'chat_memory',
            1536,
            (_) => ChatHistoryMemoryProviderState(
              ChatHistoryMemoryProviderScope(
                applicationId: 'agents_app',
                agentId: agent.id,
                // Channel conversations share channel-wide memory.
                sessionId: scope.channelId ?? scope.conversationId,
              ),
            ),
          ),
        ];
      },
    );
    flutter.wrapWith((sp, child) => child);
    flutter.runApp((services) => AgentsApp(services: services));
  });

final host = _builder.build();

Future<void> main() async => await host.run();
// </start>

enum _LocalLlamaPhase { idle, downloading, loading, ready, error }

@immutable
class _LocalLlamaStatus {
  const _LocalLlamaStatus({
    required this.phase,
    required this.message,
    this.progress,
  });

  static const idle = _LocalLlamaStatus(
    phase: _LocalLlamaPhase.idle,
    message: '',
  );

  final _LocalLlamaPhase phase;
  final String message;
  final double? progress;

  bool get isVisible => phase != _LocalLlamaPhase.idle;
}

final class _LocalLlamaProgressRegistry extends ChangeNotifier {
  final Map<String, _LocalLlamaStatus> _statuses = {};

  _LocalLlamaStatus statusFor(String modelId) =>
      _statuses[modelId] ?? _LocalLlamaStatus.idle;

  void update(String modelId, _LocalLlamaStatus status) {
    _statuses[modelId] = status;
    notifyListeners();
  }
}

final _localLlamaProgress = _LocalLlamaProgressRegistry();

@immutable
class _LocalLlamaModelLocation {
  const _LocalLlamaModelLocation({
    required this.modelUrl,
    this.localPath,
    this.mmprojLocalPath,
    this.draftLocalPath,
    this.isSelectedFile = false,
  });

  final Uri modelUrl;
  final String? localPath;
  final String? mmprojLocalPath;
  final String? draftLocalPath;
  final bool isSelectedFile;
}

ai.ChatClient _createLocalLlamaClient(
  ServiceProvider services, {
  required ModelSourceConfig source,
  required ModelConfig model,
}) {
  final location = _localLlamaModelLocation(model);
  final spec = _localLlamaSpec(
    source: source,
    model: model,
    modelUrl: location.modelUrl,
  );
  final runtime = llama.createLlamaRuntime();
  llama.LlamaSession? loaded;

  Future<llama.LlamaSession> sessionProvider() async {
    final current = loaded;
    if (current != null) return current;

    try {
      final selectedLocalPath = location.localPath;
      if (selectedLocalPath != null) {
        _localLlamaProgress.update(
          model.id,
          const _LocalLlamaStatus(
            phase: _LocalLlamaPhase.loading,
            message: 'Loading selected local model...',
          ),
        );
        loaded = await runtime.loadModel(
          spec,
          localPath: selectedLocalPath,
          localMmprojPath: location.mmprojLocalPath,
          localDraftPath: location.draftLocalPath,
        );
      } else if (kIsWeb) {
        _localLlamaProgress.update(
          model.id,
          _LocalLlamaStatus(
            phase: _LocalLlamaPhase.loading,
            message: location.isSelectedFile
                ? 'Loading selected local model...'
                : 'Loading local model from browser cache...',
          ),
        );
        loaded = await runtime.loadModel(
          spec,
          onProgress: (progress) {
            _localLlamaProgress.update(
              model.id,
              _LocalLlamaStatus(
                phase: _LocalLlamaPhase.downloading,
                message: 'Downloading local model to browser cache...',
                progress: progress.clamp(0, 1).toDouble(),
              ),
            );
          },
        );
      } else {
        final paths = await _downloadLocalModel(services, spec, model.id);
        _localLlamaProgress.update(
          model.id,
          const _LocalLlamaStatus(
            phase: _LocalLlamaPhase.loading,
            message: 'Loading local model...',
          ),
        );
        loaded = await runtime.loadModel(
          spec,
          localPath: paths.modelPath,
          localMmprojPath: paths.mmprojPath,
          localDraftPath: paths.draftPath,
        );
      }
      _localLlamaProgress.update(
        model.id,
        const _LocalLlamaStatus(
          phase: _LocalLlamaPhase.ready,
          message: 'Local model ready.',
          progress: 1,
        ),
      );
    } on Object catch (error) {
      _localLlamaProgress.update(
        model.id,
        _LocalLlamaStatus(
          phase: _LocalLlamaPhase.error,
          message: 'Local model failed: $error',
        ),
      );
      rethrow;
    }
    return loaded!;
  }

  final thinking = services.getService<ThinkingSettings>();
  return llama.createLlamaChatClient(
    spec: spec,
    sessionProvider: sessionProvider,
    // Evaluated per request, so the chat toggle applies mid-conversation.
    isThinkingEnabled: () =>
        (thinking?.enabledFor(model.id) ?? false) || spec.enableThinking,
  );
}

_LocalLlamaModelLocation _localLlamaModelLocation(ModelConfig model) {
  final settings = model.settings;
  final configuredSource = settings['llama.modelSource']?.trim();
  final modelSource = configuredSource == null || configuredSource.isEmpty
      ? settings.containsKey('llama.modelPath')
            ? 'file'
            : 'url'
      : configuredSource;

  if (modelSource == 'file') {
    // Optional artifacts resolve like the main model: prefer the
    // runtime-selected file, then the persisted native path. A persisted
    // file name without a resolvable path (a web restart) is an error so a
    // configured artifact is never silently dropped.
    String? artifactPath({
      required LlamaArtifactKind kind,
      required String pathKey,
      required String fileNameKey,
      required String label,
    }) {
      final selected = selectedLlamaModelFilePathFor(
        model.id,
        kind: kind,
      )?.trim();
      if (selected != null && selected.isNotEmpty) return selected;

      final persisted = settings[pathKey]?.trim();
      if (!kIsWeb && persisted != null && persisted.isNotEmpty) {
        return persisted;
      }

      final fileName = settings[fileNameKey]?.trim();
      if (fileName == null || fileName.isEmpty) return null;
      throw ConfiguredAgentException(
        'Reselect the $label file "$fileName" before running this local '
        'llama model.',
      );
    }

    final mmprojPath = artifactPath(
      kind: LlamaArtifactKind.mmproj,
      pathKey: 'llama.mmprojPath',
      fileNameKey: 'llama.mmprojFileName',
      label: 'projector (mmproj) GGUF',
    );
    final draftPath = artifactPath(
      kind: LlamaArtifactKind.draft,
      pathKey: 'llama.draftModelPath',
      fileNameKey: 'llama.draftModelFileName',
      label: 'draft/MTP GGUF',
    );

    final selectedPath = selectedLlamaModelFilePathFor(model.id)?.trim();
    if (selectedPath != null && selectedPath.isNotEmpty) {
      return _LocalLlamaModelLocation(
        modelUrl: kIsWeb ? Uri.parse(selectedPath) : Uri.file(selectedPath),
        localPath: selectedPath,
        mmprojLocalPath: mmprojPath,
        draftLocalPath: draftPath,
        isSelectedFile: true,
      );
    }

    final modelPath = settings['llama.modelPath']?.trim();
    if (!kIsWeb && modelPath != null && modelPath.isNotEmpty) {
      return _LocalLlamaModelLocation(
        modelUrl: Uri.file(modelPath),
        localPath: modelPath,
        mmprojLocalPath: mmprojPath,
        draftLocalPath: draftPath,
        isSelectedFile: true,
      );
    }

    final fileName = settings['llama.modelFileName']?.trim();
    final suffix = fileName == null || fileName.isEmpty ? '' : ' "$fileName"';
    throw ConfiguredAgentException(
      'Reselect the GGUF model file$suffix before running this local llama model.',
    );
  }

  if (modelSource != 'url') {
    throw ConfiguredAgentException(
      'Unsupported local llama model source "$modelSource".',
    );
  }

  final modelUrl = settings['llama.modelUrl']?.trim();
  if (modelUrl == null || modelUrl.isEmpty) {
    throw ConfiguredAgentException('Local llama model URL is required.');
  }
  return _LocalLlamaModelLocation(modelUrl: Uri.parse(modelUrl));
}

llama.ModelSpec _localLlamaSpec({
  required ModelSourceConfig source,
  required ModelConfig model,
  required Uri modelUrl,
}) {
  final settings = model.settings;
  final format = _chatFormatFor(
    settings[chatFormatSetting]?.trim().isNotEmpty ?? false
        ? settings[chatFormatSetting]
        : settings[legacyLlamaFormatSetting],
    detectionBasis:
        settings['llama.modelFileName'] ?? settings['llama.modelUrl'] ?? '',
  );

  Uri? optionalUrl(String key) {
    final value = settings[key]?.trim();
    return value == null || value.isEmpty ? null : Uri.parse(value);
  }

  int intSetting(String key, int fallback) {
    final value = settings[key]?.trim();
    if (value == null || value.isEmpty) return fallback;
    return int.tryParse(value) ?? fallback;
  }

  return llama.ModelSpec(
    id: model.modelId,
    displayName: model.label,
    modelUrl: modelUrl,
    mmprojUrl: optionalUrl('llama.mmprojUrl'),
    draftUrl: optionalUrl('llama.draftModelUrl'),
    contextSize: intSetting('llama.contextSize', 4096),
    gpuLayers: intSetting('llama.gpuLayers', 999),
    draftGpuLayers: intSetting('llama.draftGpuLayers', 999),
    maxDraftTokens: intSetting('llama.maxDraftTokens', 8),
    format: format,
  );
}

/// Maps a `chat.format`/`llama.format` setting to the chat format that
/// model family speaks.
///
/// When unset, the format is guessed from [detectionBasis] (the model's
/// file name or URL); when that finds nothing either, the registry
/// default (Gemma) applies for backwards compatibility.
llama.ChatFormat _chatFormatFor(String? format, {String detectionBasis = ''}) {
  final explicit = format?.trim() ?? '';
  final effective = explicit.isNotEmpty
      ? explicit
      : detectChatFormatName(detectionBasis) ?? '';
  final resolved = llama.resolveChatFormat(effective);
  if (resolved == null) {
    throw ConfiguredAgentException('Unsupported local llama format "$format".');
  }
  return resolved;
}

Future<({String modelPath, String? mmprojPath, String? draftPath})>
_downloadLocalModel(
  ServiceProvider services,
  llama.ModelSpec spec,
  String modelId,
) async {
  final downloads = services.getRequiredService<DownloadService>();
  final modelPath = await _downloadLocalArtifact(
    downloads,
    spec,
    modelId,
    url: spec.modelUrl,
    fallbackFilename: '$modelId.gguf',
    label: 'local model',
  );
  final mmprojUrl = spec.mmprojUrl;
  final mmprojPath = mmprojUrl == null
      ? null
      : await _downloadLocalArtifact(
          downloads,
          spec,
          modelId,
          url: mmprojUrl,
          fallbackFilename: '$modelId-mmproj.gguf',
          label: 'projector (mmproj)',
        );
  final draftUrl = spec.draftUrl;
  final draftPath = draftUrl == null
      ? null
      : await _downloadLocalArtifact(
          downloads,
          spec,
          modelId,
          url: draftUrl,
          fallbackFilename: '$modelId-draft.gguf',
          label: 'draft/MTP model',
        );
  return (modelPath: modelPath, mmprojPath: mmprojPath, draftPath: draftPath);
}

Future<String> _downloadLocalArtifact(
  DownloadService downloads,
  llama.ModelSpec spec,
  String modelId, {
  required Uri url,
  required String fallbackFilename,
  required String label,
}) async {
  final filename = url.pathSegments.isEmpty
      ? fallbackFilename
      : url.pathSegments.last;
  final request = DownloadRequest(
    url: url.toString(),
    filename: filename,
    directory: 'local_llama/$modelId',
    metaData: spec.id,
  );
  final path = await downloads.filePathFor(request);
  _localLlamaProgress.update(
    modelId,
    _LocalLlamaStatus(
      phase: _LocalLlamaPhase.downloading,
      message: 'Downloading $label...',
      progress: 0,
    ),
  );
  final status = await downloads.download(
    request,
    onProgress: (progress) {
      _localLlamaProgress.update(
        modelId,
        _LocalLlamaStatus(
          phase: _LocalLlamaPhase.downloading,
          message: 'Downloading $label...',
          progress: progress.clamp(0, 1),
        ),
      );
    },
    onStatus: (status) {
      if (status == DownloadStatus.running) {
        _localLlamaProgress.update(
          modelId,
          _LocalLlamaStatus(
            phase: _LocalLlamaPhase.downloading,
            message: 'Downloading $label...',
          ),
        );
      }
    },
  );
  if (status != DownloadStatus.complete) {
    throw ConfiguredAgentException(
      'Local llama $label download failed with status $status.',
    );
  }
  return path;
}

/// Root of the agents app: a routed shell over Chats, Tasks, and Settings.
class AgentsApp extends StatefulWidget {
  /// Creates the agents app.
  const AgentsApp({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<AgentsApp> createState() => _AgentsAppState();
}

class _AgentsAppState extends State<AgentsApp> {
  late final GoRouter _router;
  late final TaskSchedulerService _scheduler;

  @override
  void initState() {
    super.initState();
    final bootstrap = AppBootstrap(
      widget.services,
      seedApiKey: _seedApiKey,
      seedModel: _seedModel,
    );
    _scheduler = TaskSchedulerService(widget.services)..start();
    _router = createAppRouter(
      services: widget.services,
      bootstrap: bootstrap,
      scheduler: _scheduler,
    );
  }

  @override
  void dispose() {
    _scheduler.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeSettings = widget.services.getRequiredService<ThemeSettings>();
    return ListenableBuilder(
      listenable: themeSettings,
      builder: (context, _) => MaterialApp.router(
        title: 'agents_app',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          seedColor: themeSettings.seed.color,
          brightness: Brightness.light,
        ),
        darkTheme: buildAppTheme(
          seedColor: themeSettings.seed.color,
          brightness: Brightness.dark,
        ),
        themeMode: themeSettings.mode,
        routerConfig: _router,
      ),
    );
  }
}

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
  Conversation? _existingConversation;
  ModelConfig? _model;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final records = widget.services.getRequiredService<RecordStore>();
    _conversations = ConversationStore(records);
    _sessions = ConversationSessionStore(records);
    _transcripts = ChatTranscriptStore(records);
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

    // Group conversations run through the coordinator with the other
    // participants attached as background agents.
    final extraDelegations = <AgentDelegationConfig>[
      if (record != null && record.kind == ConversationKind.group)
        for (final participantId in record.participantAgentIds)
          if (participantId != widget.agent.id)
            AgentDelegationConfig(agentId: participantId),
    ];

    _model = await widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .sources
        .getModel(widget.agent.modelId);

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
    final agent = await factory.createAgent(
      widget.agent,
      scope: AgentScope(
        conversationId: _conversationId,
        sessionIdResolver: () => _sessionId,
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

  /// Maps the durable transcript to displayable UI messages.
  ///
  /// Tool-call-only turns carry no text and are skipped; the model still
  /// sees them through the chat history provider.
  Future<List<ChatMessage>> _loadDisplayHistory({String? sessionId}) async {
    final entries = await _transcripts!.load(_conversationId);
    return [
      for (final entry in entries)
        if (sessionId == null || entry.sessionId == sessionId)
          if (entry.message.text.trim().isNotEmpty)
            entry.message.role == ai.ChatRole.user
                ? ChatMessage.user(entry.message.text, const [])
                : ChatMessage(
                    origin: MessageOrigin.llm,
                    text: entry.message.text,
                    attachments: const [],
                  ),
    ];
  }

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
        ),
      );
      _conversationExists = true;

      unawaited(_persistSerializedSession(provider));
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
    await _persistMetadata(augmented);
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
                'Add to a new group chat — this conversation stays as is.',
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

    // Any participant can coordinate; the current agent is the default.
    final coordinator = await showDialog<SavedAgentConfig>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Who coordinates the group?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(widget.agent),
            child: Text('${widget.agent.name} (recommended)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(added),
            child: Text(added.name),
          ),
        ],
      ),
    );
    if (coordinator == null || !mounted) return;

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

  /// Ends the current session and starts a fresh one.
  ///
  /// The conversation and its transcript continue (stitched display and
  /// model context are conversation-scoped); only the session epoch — the
  /// serialized agent-session state new turns are stamped with — resets.
  Future<void> _startNewSession() async {
    final provider = _provider;
    if (provider == null) return;
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
    );
    if (!deleted) return;
    _deleted = true;
    if (mounted) context.go('/chats');
  }

  void _setDefaultTitleFrom(List<ChatMessage> history) {
    if (_titleSource != ConversationTitleSource.none) return;
    for (final message in history) {
      if (!message.origin.isUser) continue;
      final text = message.text?.trim();
      if (text == null || text.isEmpty) continue;
      _title = _truncateTitle(text);
      _titleSource = ConversationTitleSource.firstMessage;
      _refreshTitle();
      return;
    }
  }

  String _truncateTitle(String text) {
    const maxLength = 80;
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.length <= maxLength) return collapsed;
    return '${collapsed.substring(0, maxLength - 1)}…';
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
    unawaited(_finishStateChangesBeforePop());
    _provider?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: widget.embedded,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) return;
      unawaited(_handlePop());
    },
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isPrivate) ...[
              Tooltip(
                message: 'Private chat — nothing is saved',
                child: Icon(
                  Icons.visibility_off_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(_appBarTitle, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          if (!widget.isPrivate && _sessionList.length > 1)
            PopupMenuButton<String?>(
              tooltip: 'View a session',
              icon: Icon(
                Icons.history,
                color: _viewSessionId == null
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
              onSelected: _viewSession,
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: null,
                  checked: _viewSessionId == null,
                  child: const Text('All sessions (stitched)'),
                ),
                for (final session in _sessionList)
                  CheckedPopupMenuItem(
                    value: session.id,
                    checked: _viewSessionId == session.id,
                    child: Text(
                      '${formatConversationDate(session.startedAt)}'
                      '${session.id == _sessionId ? ' • current' : ''}',
                    ),
                  ),
              ],
            ),
          if (_model case final model? when model.capabilities.supportsThinking)
            _ThinkingToggle(services: widget.services, modelConfigId: model.id),
          if (!widget.isPrivate)
            PopupMenuButton<void Function()>(
              tooltip: 'Conversation actions',
              onSelected: (action) => action(),
              itemBuilder: (context) => [
                PopupMenuItem(
                  enabled: _provider != null,
                  value: () => unawaited(_startNewSession()),
                  child: const Text('New session'),
                ),
                PopupMenuItem(
                  enabled: _provider != null,
                  value: () => unawaited(_addAgentToChat()),
                  child: const Text('Add agent to chat'),
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
            ),
        ],
      ),
      body: FutureBuilder<AgentLlmProvider>(
        future: _providerFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _AgentStartError(
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
          return Column(
            children: [
              _LocalLlamaProgressBanner(modelId: widget.agent.modelId),
              Expanded(
                child: LlmChatView(
                  provider: provider,
                  onMessageSubmitted: (prompt, {required attachments}) =>
                      _persistSubmittedPrompt(provider, prompt, attachments),
                  welcomeMessage: 'Ask ${widget.agent.name} anything.',
                  enableAttachments: false,
                  enableVoiceNotes: false,
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Friendly failure state when an agent cannot start, with recovery
/// actions instead of a dead end.
class _AgentStartError extends StatelessWidget {
  const _AgentStartError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Could not start this agent',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '$error',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.go('/settings/agents'),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Check configuration'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Toggles extended reasoning for the chat's model.
///
/// Shown only when the model's capabilities advertise thinking support;
/// applies live because the client reads the setting per request.
class _ThinkingToggle extends StatefulWidget {
  const _ThinkingToggle({required this.services, required this.modelConfigId});

  final ServiceProvider services;
  final String modelConfigId;

  @override
  State<_ThinkingToggle> createState() => _ThinkingToggleState();
}

class _ThinkingToggleState extends State<_ThinkingToggle> {
  ThinkingSettings get _settings =>
      widget.services.getRequiredService<ThinkingSettings>();

  @override
  Widget build(BuildContext context) {
    final enabled = _settings.enabledFor(widget.modelConfigId);
    return IconButton(
      tooltip: enabled ? 'Thinking on' : 'Thinking off',
      icon: Icon(
        Icons.psychology_outlined,
        color: enabled ? Theme.of(context).colorScheme.primary : null,
      ),
      onPressed: () async {
        await _settings.setEnabled(widget.modelConfigId, !enabled);
        if (mounted) setState(() {});
      },
    );
  }
}

class _LocalLlamaProgressBanner extends StatelessWidget {
  const _LocalLlamaProgressBanner({required this.modelId});

  final String modelId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _localLlamaProgress,
    builder: (context, child) {
      final status = _localLlamaProgress.statusFor(modelId);
      if (!status.isVisible) return const SizedBox.shrink();

      final colorScheme = Theme.of(context).colorScheme;
      final progress = status.progress;
      final isBusy =
          status.phase == _LocalLlamaPhase.downloading ||
          status.phase == _LocalLlamaPhase.loading;

      return Material(
        color: status.phase == _LocalLlamaPhase.error
            ? colorScheme.errorContainer
            : colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isBusy) ...[
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: status.phase == _LocalLlamaPhase.downloading
                            ? progress
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else
                    Icon(
                      status.phase == _LocalLlamaPhase.error
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 18,
                      color: status.phase == _LocalLlamaPhase.error
                          ? colorScheme.onErrorContainer
                          : colorScheme.primary,
                    ),
                  if (!isBusy) const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusText(status),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: status.phase == _LocalLlamaPhase.error
                            ? colorScheme.onErrorContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (status.phase == _LocalLlamaPhase.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress),
              ],
            ],
          ),
        ),
      );
    },
  );

  String _statusText(_LocalLlamaStatus status) {
    final progress = status.progress;
    if (status.phase == _LocalLlamaPhase.downloading && progress != null) {
      return '${status.message} ${(progress * 100).toStringAsFixed(0)}%';
    }
    return status.message;
  }
}

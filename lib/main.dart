import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents/agents.dart'
    show
        AIAgent,
        AgentSession,
        ChatHistoryProvider,
        InMemoryChatHistoryProvider;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_llama/agents_llama.dart' as llama;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:extensions/extensions.dart' hide ChatMessage;

import 'ui/chat_sessions/chat_session_record.dart';
import 'ui/chat_sessions/chat_session_store.dart';
import 'ui/providers/providers.dart';
import 'ui/views/configured_agents/configured_agents.dart';
import 'ui/views/llm_chat_view/llm_chat_view.dart';

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
    flutter.useFlutterHarnessAgent();
    flutter.useConfiguredAgents(
      chatClientFactory: (sp) => ConfiguredChatClientFactory(
        customClientResolver: ({required source, required model, httpClient}) =>
            _createLocalLlamaClient(sp, source: source, model: model),
      ),
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

  return llama.createLlamaChatClient(
    spec: spec,
    sessionProvider: sessionProvider,
    isThinkingEnabled: () => spec.enableThinking,
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

/// Root of the configured-agents app.
class AgentsApp extends StatelessWidget {
  /// Creates the agents app.
  const AgentsApp({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'agents_app',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      textTheme: GoogleFonts.outfitTextTheme(),
      useMaterial3: true,
    ),
    home: HomeScreen(services: services),
  );
}

/// Lists configured agents and opens the settings surface and chat.
class HomeScreen extends StatefulWidget {
  /// Creates a [HomeScreen].
  const HomeScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final Future<void> _ready;
  bool _initialized = false;

  // Bumped whenever the saved agents may have changed (e.g. after returning
  // from settings) to force [_AgentList] to rebuild from storage.
  int _agentListToken = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _ready = _seedIfNeeded(
      widget.services.getRequiredService<ConfiguredAgentsManager>(),
    );
  }

  Future<void> _seedIfNeeded(ConfiguredAgentsManager manager) async {
    if (_seedApiKey.trim().isEmpty) return;
    final existing = await manager.sources.listSources();
    if (existing.isNotEmpty) return;

    const sourceId = 'seed-anthropic';
    const modelId = 'seed-anthropic-model';
    await manager.saveSource(
      const ModelSourceConfig(
        id: sourceId,
        providerType: ProviderType.anthropic,
        displayName: 'Anthropic (seeded)',
      ),
      apiKey: _seedApiKey,
    );
    await manager.saveModel(
      const ModelConfig(
        id: modelId,
        sourceId: sourceId,
        modelId: _seedModel,
        displayName: 'Claude',
      ),
    );
    await manager.saveAgent(
      const SavedAgentConfig(
        id: 'seed-anthropic-agent',
        name: 'Claude',
        modelId: modelId,
        description: 'A helpful assistant.',
        instructions: 'You are a helpful, concise assistant.',
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(services: widget.services),
      ),
    );
    if (mounted) {
      setState(() => _agentListToken++);
    }
  }

  void _openConversations(SavedAgentConfig agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AgentConversationsScreen(agent: agent, services: widget.services),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Configured agents'),
      actions: [
        IconButton(
          tooltip: 'Manage',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
      ],
    ),
    body: FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return _AgentList(
          key: ValueKey(_agentListToken),
          services: widget.services,
          onSelected: _openConversations,
          onManage: _openSettings,
        );
      },
    ),
  );
}

class _AgentList extends StatefulWidget {
  const _AgentList({
    required this.services,
    required this.onSelected,
    required this.onManage,
    super.key,
  });

  final ServiceProvider services;
  final void Function(SavedAgentConfig agent) onSelected;
  final VoidCallback onManage;

  @override
  State<_AgentList> createState() => _AgentListState();
}

class _AgentListState extends State<_AgentList> {
  late final Future<List<SavedAgentConfig>> _agents;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _agents = widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agents
        .listAgents();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<SavedAgentConfig>>(
    future: _agents,
    builder: (context, snapshot) {
      final agents = snapshot.data ?? const <SavedAgentConfig>[];
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (agents.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'No agents yet. Add a source, model, and agent to begin.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.onManage,
                  icon: const Icon(Icons.add),
                  label: const Text('Manage agents'),
                ),
              ],
            ),
          ),
        );
      }
      return ConfiguredAgentPicker(
        agents: agents,
        onSelected: widget.onSelected,
      );
    },
  );
}

/// Lists saved conversations for one agent.
class AgentConversationsScreen extends StatefulWidget {
  /// Creates an [AgentConversationsScreen].
  const AgentConversationsScreen({
    required this.agent,
    required this.services,
    super.key,
  });

  /// The saved agent whose conversations should be listed.
  final SavedAgentConfig agent;

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<AgentConversationsScreen> createState() =>
      _AgentConversationsScreenState();
}

class _AgentConversationsScreenState extends State<AgentConversationsScreen> {
  late final ChatSessionStore _store;
  late Future<List<ChatSessionRecord>> _conversations;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _store = ChatSessionStore(
      widget.services.getRequiredService<KeyValueStore>(),
    );
    _reload();
  }

  void _reload() {
    _conversations = _listConversations();
  }

  Future<List<ChatSessionRecord>> _listConversations() async {
    final conversations = await _store.list(widget.agent.id);
    if (conversations.isNotEmpty) return conversations;
    return _store.listAll();
  }

  Future<void> _openNewChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatScreen(agent: widget.agent, services: widget.services),
      ),
    );
    if (mounted) {
      setState(_reload);
    }
  }

  Future<void> _openConversation(ChatSessionRecord conversation) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          agent: widget.agent,
          services: widget.services,
          conversationId: conversation.id,
        ),
      ),
    );
    if (mounted) {
      setState(_reload);
    }
  }

  Future<void> _renameConversation(ChatSessionRecord conversation) async {
    final title = await _showConversationTitleDialog(
      context,
      initialTitle: conversation.title,
    );
    if (title == null) return;

    await _store.save(
      ChatSessionRecord(
        id: conversation.id,
        agentId: conversation.agentId,
        title: title,
        titleSource: ChatSessionTitleSource.manual,
        history: conversation.history,
        createdAt: conversation.createdAt,
        updatedAt: DateTime.now(),
        serializedSession: conversation.serializedSession,
      ),
    );
    if (mounted) {
      setState(_reload);
    }
  }

  Future<void> _deleteConversation(ChatSessionRecord conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          'Delete "${_conversationTitle(conversation)}"? This cannot be undone.',
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

    await _store.delete(conversation.id);
    if (mounted) {
      setState(_reload);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.agent.name),
      actions: [
        IconButton(
          tooltip: 'New chat',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: _openNewChat,
        ),
      ],
    ),
    body: FutureBuilder<List<ChatSessionRecord>>(
      future: _conversations,
      builder: (context, snapshot) {
        final conversations = snapshot.data ?? const <ChatSessionRecord>[];
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (conversations.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'No conversations yet.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _openNewChat,
                    icon: const Icon(Icons.add),
                    label: const Text('New chat'),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.builder(
          itemCount: conversations.length,
          itemBuilder: (context, index) {
            final conversation = conversations[index];
            return ListTile(
              title: Text(_conversationTitle(conversation)),
              subtitle: Text(
                '${_formatConversationDate(conversation.updatedAt)}'
                ' • ${_messageCountLabel(conversation.history.length)}',
              ),
              onTap: () => _openConversation(conversation),
              trailing: PopupMenuButton<_ConversationAction>(
                tooltip: 'Conversation actions',
                onSelected: (action) {
                  switch (action) {
                    case _ConversationAction.rename:
                      unawaited(_renameConversation(conversation));
                      break;
                    case _ConversationAction.delete:
                      unawaited(_deleteConversation(conversation));
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _ConversationAction.rename,
                    child: Text('Rename'),
                  ),
                  PopupMenuItem(
                    value: _ConversationAction.delete,
                    child: Text('Delete'),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

enum _ConversationAction { rename, delete }

String _conversationTitle(ChatSessionRecord conversation) =>
    conversation.title.trim().isEmpty
    ? 'Untitled conversation'
    : conversation.title.trim();

String _messageCountLabel(int count) =>
    count == 1 ? '1 message' : '$count messages';

String _formatConversationDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

Future<String?> _showConversationTitleDialog(
  BuildContext context, {
  required String initialTitle,
}) async {
  var title = initialTitle;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename conversation'),
      content: TextFormField(
        initialValue: initialTitle,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Title'),
        textInputAction: TextInputAction.done,
        onChanged: (value) => title = value,
        onFieldSubmitted: (_) {
          final trimmed = title.trim();
          if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final trimmed = title.trim();
            if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// The settings surface, composed entirely from the package's
/// [ConfiguredAgentsView].
class SettingsScreen extends StatelessWidget {
  /// Creates a [SettingsScreen].
  const SettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final manager = services.getRequiredService<ConfiguredAgentsManager>();
    return Scaffold(
      appBar: AppBar(title: const Text('Manage agents')),
      body: Column(
        children: [
          const _WebSecurityNotice(),
          Expanded(child: ConfiguredAgentsView(manager: manager)),
        ],
      ),
    );
  }
}

class _WebSecurityNotice extends StatelessWidget {
  const _WebSecurityNotice();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.all(12),
    child: Text(
      'Keys are stored in secure storage. On the web this falls back to '
      'browser storage, which does not protect secrets — production apps '
      'should proxy provider requests through a backend.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

/// Resolves a saved agent and shows a chat against it.
class ChatScreen extends StatefulWidget {
  /// Creates a [ChatScreen].
  const ChatScreen({
    required this.agent,
    required this.services,
    this.conversationId,
    super.key,
  });

  /// The saved agent to chat with.
  final SavedAgentConfig agent;

  /// The application service provider.
  final ServiceProvider services;

  /// The conversation to resume, or `null` to start a blank conversation.
  final String? conversationId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final Future<AgentLlmProvider> _providerFuture;
  bool _initialized = false;
  AgentLlmProvider? _provider;
  ChatSessionStore? _store;
  String? _conversationId;
  String _title = '';
  ChatSessionTitleSource _titleSource = ChatSessionTitleSource.none;
  DateTime? _createdAt;
  Future<void> _pendingPersistence = Future<void>.value();
  bool _isPopping = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _store = ChatSessionStore(
      widget.services.getRequiredService<KeyValueStore>(),
    );
    _providerFuture = _createProvider(
      widget.services.getRequiredService<ConfiguredAgentFactory>(),
      _store!,
    );
  }

  Future<AgentLlmProvider> _createProvider(
    ConfiguredAgentFactory factory,
    ChatSessionStore store,
  ) async {
    final conversationId = widget.conversationId;
    final record = conversationId == null
        ? null
        : await store.load(conversationId);
    _conversationId = record?.id ?? conversationId;
    _title = record?.title ?? '';
    _titleSource = record?.titleSource ?? ChatSessionTitleSource.none;
    _createdAt = record?.createdAt;

    final agent = await factory.createAgent(widget.agent);
    final serialized = record?.serializedSession;
    final session = serialized != null
        ? await agent.deserializeSession(serialized)
        : await agent.createSession();

    if (record != null) {
      _seedAgentHistory(agent, session, record.history);
    }

    final provider = AgentLlmProvider(
      agent: agent,
      session: session,
      history: record?.history ?? const [],
    );
    // Attach after restore so persistence reflects ongoing turns only.
    provider.addListener(() {
      _pendingPersistence = _persist(store, agent, session, provider);
    });
    _provider = provider;
    _refreshTitle();
    return provider;
  }

  /// Re-seeds the agent's in-memory chat history from a restored transcript.
  ///
  /// Serialized sessions for in-memory history providers only carry a
  /// conversation id, so the prior context must be replayed here for the next
  /// model call to see it. Sessions with a server-managed conversation id
  /// ignore the seed.
  void _seedAgentHistory(
    AIAgent agent,
    AgentSession session,
    List<ChatMessage> history,
  ) {
    final provider = agent.getServiceOf<ChatHistoryProvider>();
    if (provider is! InMemoryChatHistoryProvider) return;
    provider.setMessages(session, [
      for (final message in history)
        if (message.text != null && message.text!.isNotEmpty)
          ai.ChatMessage.fromText(
            message.origin.isUser ? ai.ChatRole.user : ai.ChatRole.assistant,
            message.text!,
          ),
    ]);
  }

  Future<void> _persist(
    ChatSessionStore store,
    AIAgent agent,
    AgentSession session,
    AgentLlmProvider provider,
  ) async {
    try {
      final history = provider.history.toList();
      if (history.isEmpty) return;

      // Eagerly assign the conversation identity before any async work so
      // the record is findable as soon as the first user message arrives.
      final now = DateTime.now();
      _createdAt ??= now;
      _conversationId ??= store.createConversationId();
      _setDefaultTitleFrom(history);

      // Save an optimistic record immediately (no serialized session yet) so
      // the conversation shows up in the list right away.
      await store.save(
        ChatSessionRecord(
          id: _conversationId!,
          agentId: widget.agent.id,
          title: _title,
          titleSource: _titleSource,
          history: history,
          createdAt: _createdAt!,
          updatedAt: now,
        ),
      );

      unawaited(
        _persistSerializedSession(store, agent, session, _conversationId!),
      );
    } catch (e, s) {
      developer.log(
        'Failed to persist chat session.',
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
    final store = _store;
    if (store == null) return;

    try {
      final text = prompt.trim();
      if (text.isEmpty) return;

      final now = DateTime.now();
      _createdAt ??= now;
      _conversationId ??= store.createConversationId();

      final history = [
        ...provider.history,
        ChatMessage.user(prompt, attachments),
      ];
      _setDefaultTitleFrom(history);

      await store.save(
        ChatSessionRecord(
          id: _conversationId!,
          agentId: widget.agent.id,
          title: _title,
          titleSource: _titleSource,
          history: history,
          createdAt: _createdAt!,
          updatedAt: now,
        ),
      );
    } catch (e, s) {
      developer.log(
        'Failed to persist submitted chat prompt.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _persistSerializedSession(
    ChatSessionStore store,
    AIAgent agent,
    AgentSession session,
    String conversationId,
  ) async {
    try {
      final serializedSession = await _serializeSession(agent, session);
      if (serializedSession == null) return;

      final current = await store.load(conversationId);
      if (current == null || current.history.isEmpty) return;
      await store.save(
        ChatSessionRecord(
          id: current.id,
          agentId: current.agentId,
          title: current.title,
          titleSource: current.titleSource,
          history: current.history,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
          serializedSession: serializedSession,
        ),
      );
    } catch (e, s) {
      developer.log(
        'Failed to update persisted chat session state.',
        name: 'agents_app.chat_sessions',
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _discardEmptyConversation() async {
    final store = _store;
    final conversationId = _conversationId;
    final provider = _provider;
    if (store == null || conversationId == null || provider == null) return;
    if (provider.history.isNotEmpty) return;

    try {
      final saved = await store.load(conversationId);
      if (saved != null && saved.history.isNotEmpty) return;
      await store.delete(conversationId);
    } catch (e, s) {
      developer.log(
        'Failed to discard empty chat session.',
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

  Future<void> _renameConversation() async {
    final store = _store;
    final provider = _provider;
    if (store == null || provider == null) return;

    final title = await _showConversationTitleDialog(
      context,
      initialTitle: _title,
    );
    if (title == null) return;

    setState(() {
      _title = title;
      _titleSource = ChatSessionTitleSource.manual;
    });
    _pendingPersistence = _persist(
      store,
      provider.agent,
      provider.session!,
      provider,
    );
    await _pendingPersistence;
  }

  void _setDefaultTitleFrom(List<ChatMessage> history) {
    if (_titleSource != ChatSessionTitleSource.none) return;
    for (final message in history) {
      if (!message.origin.isUser) continue;
      final text = message.text?.trim();
      if (text == null || text.isEmpty) continue;
      _title = _truncateTitle(text);
      _titleSource = ChatSessionTitleSource.firstMessage;
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
    await _pendingPersistence;
    await _flushLatestConversationState();
    await _discardEmptyConversation();
  }

  Future<void> _flushLatestConversationState() async {
    final store = _store;
    final provider = _provider;
    final session = provider?.session;
    if (store == null ||
        provider == null ||
        session == null ||
        provider.history.isEmpty) {
      return;
    }

    _pendingPersistence = _persist(store, provider.agent, session, provider);
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
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) return;
      unawaited(_handlePop());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle),
        actions: [
          IconButton(
            tooltip: 'Rename conversation',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _provider == null ? null : _renameConversation,
          ),
        ],
      ),
      body: FutureBuilder<AgentLlmProvider>(
        future: _providerFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not start the agent.\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
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

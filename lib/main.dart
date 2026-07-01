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
    this.isSelectedFile = false,
  });

  final Uri modelUrl;
  final String? localPath;
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
        loaded = await runtime.loadModel(spec, localPath: selectedLocalPath);
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
        final localPath = await _downloadLocalModel(services, spec, model.id);
        _localLlamaProgress.update(
          model.id,
          const _LocalLlamaStatus(
            phase: _LocalLlamaPhase.loading,
            message: 'Loading local model...',
          ),
        );
        loaded = await runtime.loadModel(spec, localPath: localPath);
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
    final selectedPath = selectedLlamaModelFilePathFor(model.id)?.trim();
    if (selectedPath != null && selectedPath.isNotEmpty) {
      return _LocalLlamaModelLocation(
        modelUrl: kIsWeb ? Uri.parse(selectedPath) : Uri.file(selectedPath),
        localPath: selectedPath,
        isSelectedFile: true,
      );
    }

    final modelPath = settings['llama.modelPath']?.trim();
    if (!kIsWeb && modelPath != null && modelPath.isNotEmpty) {
      return _LocalLlamaModelLocation(
        modelUrl: Uri.file(modelPath),
        localPath: modelPath,
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
  final format = _chatFormatFor(settings['llama.format']?.trim());

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
    format: format,
  );
}

/// Maps a `llama.format` setting to the chat format that model family speaks.
///
/// Defaults to Gemma when unset for backwards compatibility.
llama.ChatFormat _chatFormatFor(String? format) {
  final resolved = llama.resolveChatFormat(format);
  if (resolved == null) {
    throw ConfiguredAgentException('Unsupported local llama format "$format".');
  }
  return resolved;
}

Future<String> _downloadLocalModel(
  ServiceProvider services,
  llama.ModelSpec spec,
  String modelId,
) async {
  final downloads = services.getRequiredService<DownloadService>();
  final filename = spec.modelUrl.pathSegments.isEmpty
      ? '$modelId.gguf'
      : spec.modelUrl.pathSegments.last;
  final request = DownloadRequest(
    url: spec.modelUrl.toString(),
    filename: filename,
    directory: 'local_llama/$modelId',
    metaData: spec.id,
  );
  final path = await downloads.filePathFor(request);
  _localLlamaProgress.update(
    modelId,
    const _LocalLlamaStatus(
      phase: _LocalLlamaPhase.downloading,
      message: 'Downloading local model...',
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
          message: 'Downloading local model...',
          progress: progress.clamp(0, 1),
        ),
      );
    },
    onStatus: (status) {
      if (status == DownloadStatus.running) {
        _localLlamaProgress.update(
          modelId,
          const _LocalLlamaStatus(
            phase: _LocalLlamaPhase.downloading,
            message: 'Downloading local model...',
          ),
        );
      }
    },
  );
  if (status != DownloadStatus.complete) {
    throw ConfiguredAgentException(
      'Local llama model download failed with status $status.',
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

  void _openChat(SavedAgentConfig agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(agent: agent, services: widget.services),
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
          onSelected: _openChat,
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
  const ChatScreen({required this.agent, required this.services, super.key});

  /// The saved agent to chat with.
  final SavedAgentConfig agent;

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final Future<AgentLlmProvider> _providerFuture;
  bool _initialized = false;
  AgentLlmProvider? _provider;
  DateTime? _createdAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _providerFuture = _createProvider(
      widget.services.getRequiredService<ConfiguredAgentFactory>(),
      ChatSessionStore(widget.services.getRequiredService<KeyValueStore>()),
    );
  }

  Future<AgentLlmProvider> _createProvider(
    ConfiguredAgentFactory factory,
    ChatSessionStore store,
  ) async {
    final record = await store.load(widget.agent.id);
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
    provider.addListener(() => _persist(store, agent, session, provider));
    _provider = provider;
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
      final serialized = await agent.serializeSession(session);
      final now = DateTime.now();
      _createdAt ??= now;
      await store.save(
        ChatSessionRecord(
          agentId: widget.agent.id,
          history: provider.history.toList(),
          createdAt: _createdAt!,
          updatedAt: now,
          serializedSession: serialized is String ? serialized : null,
        ),
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

  @override
  void dispose() {
    _provider?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.agent.name)),
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
                welcomeMessage: 'Ask ${widget.agent.name} anything.',
                enableAttachments: false,
                enableVoiceNotes: false,
              ),
            ),
          ],
        );
      },
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

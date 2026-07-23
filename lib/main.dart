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
import 'package:llama_cpp_flutter/chat.dart' as llama;
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;
import 'package:llama_cpp_flutter/orchestration.dart' as llama;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, rootBundle;

import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'data/app_activity_monitor.dart';
import 'data/chat_title_summarizer.dart';
import 'data/chat_transcript_store.dart';
import 'data/conversation_service.dart';
import 'data/conversation_store.dart';
import 'data/embedding_settings.dart';
import 'data/local_llama_context_planner.dart';
import 'data/local_llama_lease_client.dart';
import 'data/local_llama_model_host.dart';
import 'data/prompt_log.dart';
import 'data/prompt_logging.dart';
import 'data/task_scheduler_service.dart';
import 'data/theme_settings.dart';
import 'data/thinking_settings.dart';
import 'data/tool_activity.dart';
import 'data/usage_store.dart';
import 'domain/agent_task.dart' show taskPromptAuthorName;
import 'domain/conversation.dart';
import 'features/inventory/inventory_store.dart';
import 'features/inventory/inventory_tools.dart';
import 'navigation/app_bootstrap.dart';
import 'navigation/app_router.dart';
import 'ui/app_theme.dart';
import 'ui/providers/providers.dart';
import 'ui/screens/chats_home.dart' show detailPaneLeading;
import 'ui/views/configured_agents/configured_agents.dart';
import 'ui/views/llm_chat_view/llm_chat_view.dart';
import 'ui/widgets/chat_side_panel.dart';
import 'ui/widgets/conversation_actions.dart';
import 'ui/widgets/side_panel_host.dart';
import 'ui/widgets/prompt_inspector_panel.dart';
import 'ui/widgets/usage_stats_sheet.dart';

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
  ..services.addFlutter((flutter) {
    // Captures every Logger event into an in-app store with runtime level
    // controls (Settings > Logs & diagnostics). Replaces the old blanket
    // trace minimum level, which logged every streamed update.
    flutter.useAppLogging();
    flutter.services.addDownloadService();
    flutter.services.addRecordStore();
    flutter.services.tryAddSingleton<ThemeSettings>(
      (sp) => ThemeSettings(sp.getRequiredService<KeyValueStore>()),
    );
    // Unified log of every prompt sent to any model (local or cloud), so the
    // in-app inspector shows exactly what each model received.
    flutter.services.tryAddSingleton<PromptLog>((sp) => PromptLog());
    // Durable ledger of every model call's token usage, per conversation.
    flutter.services.tryAddSingleton<UsageStore>(
      (sp) => UsageStore(sp.getRequiredService<RecordStore>()),
    );
    // The local llama render seam writes its exact wire-format prompt through
    // a PromptInspector; the bridging subclass mirrors those into the shared
    // PromptLog alongside cloud requests.
    flutter.services.tryAddSingleton<llama.PromptInspector>(
      (sp) => PromptLogInspector(sp.getRequiredService<PromptLog>()),
    );
    flutter.services.tryAddSingleton<ThinkingSettings>(
      (sp) => ThinkingSettings(sp.getRequiredService<KeyValueStore>()),
    );
    // Live "which tool is the model running" signal, driven from inside the
    // chat client pipeline and mirrored under the streaming chat bubble.
    flutter.services.tryAddSingleton<ToolActivity>((sp) => ToolActivity());
    // Holds the one resident local llama model: same-model agent switches
    // reuse it, a different model evicts and reloads it, and it is never more
    // than one model at a time.
    flutter.services.tryAddSingleton<LocalLlamaModelHost>(
      (sp) => LocalLlamaModelHost(),
    );
    // App-wide idle signal: fed by the widget root (pointer/keyboard/lifecycle)
    // and by AgentLlmProvider (generation in flight); read by the background
    // title summarizer to decide when it is safe to work.
    flutter.services.tryAddSingleton<AppActivityMonitor>(
      (sp) => AppActivityMonitor(),
    );
    // Names conversations from their content using whatever local model is
    // already resident, while the app is idle. Runs under the Host lifecycle.
    flutter.services.addHostedService<ChatTitleSummarizer>(
      (sp) => ChatTitleSummarizer(
        conversations: ConversationStore(sp.getRequiredService<RecordStore>()),
        transcripts: ChatTranscriptStore(sp.getRequiredService<RecordStore>()),
        activity: sp.getRequiredService<AppActivityMonitor>(),
        residentTitleClient: () => _residentTitleClient(sp),
        loggerFactory: sp.getRequiredService<LoggerFactory>(),
      ),
    );
    // App-wide item inventory the agents manage through the inventory
    // tools. sqflite has no web backend wired up here, so the store — and
    // with it the tools — exists only on native builds.
    if (!kIsWeb) {
      flutter.services.tryAddSingleton<InventoryStore>(
        (sp) => InventoryStore(
          sqflite.databaseFactory,
          resolvePath: () async =>
              path.join(await sqflite.getDatabasesPath(), 'inventory.db'),
        ),
      );
    }
    flutter.services.tryAddSingleton<EmbeddingSettings>(
      (sp) => EmbeddingSettings(
        keyValueStore: sp.getRequiredService<KeyValueStore>(),
        manager: sp.getRequiredService<ConfiguredAgentsManager>(),
      ),
    );
    flutter.useFlutterHarnessAgent();
    flutter.useConfiguredAgents(
      // One summary log record per agent run (request in, response out) in
      // the Agents.Traffic category — never one record per streamed update.
      logAgentTraffic: true,
      chatClientFactory: (sp) => LoggingConfiguredChatClientFactory(
        log: sp.getRequiredService<PromptLog>(),
        usageSink: sp.getRequiredService<UsageStore>(),
        toolActivity: sp.getRequiredService<ToolActivity>(),
        localClientResolver: ({required source, required model, scope}) =>
            _createLocalLlamaClient(
              sp,
              source: source,
              model: model,
              scope: scope,
            ),
      ),
      configureHarnessForScope: (sp) => (agent, options, scope) {
        // The shared inventory is app-wide, not conversation-scoped, so
        // every agent gets the tools — private chats included. The store
        // is absent on web, where sqflite has no backend.
        final inventory = sp.getService<InventoryStore>();
        if (inventory != null) {
          final chatOptions = options.chatOptions ?? ai.ChatOptions();
          chatOptions.tools = [
            ...?chatOptions.tools,
            ...createInventoryTools(inventory),
          ];
          options.chatOptions = chatOptions;
        }

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
          // Old time lookups replay as expired markers so the model calls
          // the tool again instead of parroting a past session's clock.
          staleToolResultNames: const {currentTimeToolName},
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

Future<void> main() async {
  // Outfit ships as bundled assets (assets/google_fonts/), so startup never
  // depends on fonts.gstatic.com; fail loudly in debug if a weight ever
  // falls off the bundle instead of silently fetching.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['google_fonts'], license);
  });
  await host.run();
}
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
  final Map<String, Timer> _dismissTimers = {};

  // How long the "ready" banner lingers before it clears itself, long enough
  // to read the confirmation (and the web single-threaded warning) without
  // leaving the banner up for the whole chat session.
  static const _readyLinger = Duration(seconds: 6);

  _LocalLlamaStatus statusFor(String modelId) =>
      _statuses[modelId] ?? _LocalLlamaStatus.idle;

  void update(String modelId, _LocalLlamaStatus status) {
    _dismissTimers.remove(modelId)?.cancel();
    _statuses[modelId] = status;
    if (status.phase == _LocalLlamaPhase.ready) {
      _dismissTimers[modelId] = Timer(_readyLinger, () {
        _dismissTimers.remove(modelId);
        _statuses[modelId] = _LocalLlamaStatus.idle;
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

final _localLlamaProgress = _LocalLlamaProgressRegistry();

// Chat formats sniffed from a GGUF's own metadata, keyed by the same load key
// the model host uses. The client that first loads a model records the result
// here so a later same-model agent — which reuses the resident session and so
// never re-runs the sniff — renders with the same format instead of falling
// back to the file-name guess.
final Map<String, llama.ChatFormat?> _resolvedLlamaFormats =
    <String, llama.ChatFormat?>{};

// Memory-planned context sizes, keyed by the same load key. Recorded by the
// loader when the planner shrank the context below the configured size, so
// session-bound chat clients — including ones built later against a resident
// session whose loader never re-ran — budget prompts against the context the
// session actually has rather than the configured maximum.
final Map<String, int> _plannedLocalContextTokens = <String, int>{};

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

/// Config behind each resident local-model load key, so the title summarizer
/// can rebuild a client for whatever model [LocalLlamaModelHost] currently
/// holds and reuse its session through an acquire cache hit.
final Map<String, ({ModelSourceConfig source, ModelConfig model})>
_residentLocalConfigs = {};

/// A chat client bound to the resident local model, or null when none is
/// loaded. Reuses the resident session with no load and no eviction by asking
/// [_createLocalLlamaClient] for exactly the resident load key.
ai.ChatClient? _residentTitleClient(ServiceProvider services) {
  final host = services.getRequiredService<LocalLlamaModelHost>();
  final key = host.currentKey;
  if (key == null) return null;
  final config = _residentLocalConfigs[key];
  if (config == null) return null;
  return _createLocalLlamaClient(
    services,
    source: config.source,
    model: config.model,
    forTitle: true,
  );
}

/// Monotonic id for scope-less local clients, so unrelated internal calls
/// never share a KV owner key accidentally.
int _internalLocalOwnerSeq = 0;

ai.ChatClient _createLocalLlamaClient(
  ServiceProvider services, {
  required ModelSourceConfig source,
  required ModelConfig model,
  AgentScope? scope,
  bool forTitle = false,
}) {
  final location = _localLlamaModelLocation(model);
  final spec = _localLlamaSpec(
    source: source,
    model: model,
    modelUrl: location.modelUrl,
  );
  final host = services.getRequiredService<LocalLlamaModelHost>();

  // Identifies the model, its artifacts, and its load parameters so the host
  // reuses the resident session when another agent shares the same local model
  // and reloads only when the model actually differs.
  final loadKey = <Object?>[
    model.id,
    location.localPath ?? location.modelUrl.toString(),
    location.mmprojLocalPath ?? '',
    location.draftLocalPath ?? '',
    spec.contextSize,
    spec.gpuLayers,
    spec.draftGpuLayers,
    spec.maxDraftTokens,
  ].join('|');

  // Remember the config behind this load key so the title summarizer can
  // rebuild a client for whatever model the host currently holds.
  _residentLocalConfigs[loadKey] = (source: source, model: model);

  // Format chosen from the GGUF's own metadata during load. The embedded
  // chat template is what the model was actually trained on, so it beats
  // the file-name guess baked into the spec; an explicit chat.format
  // setting still beats both.
  llama.ChatFormat? ggufFormat;
  final explicitFormat =
      (model.settings[chatFormatSetting]?.trim().isNotEmpty ?? false) ||
      (model.settings[legacyLlamaFormatSetting]?.trim().isNotEmpty ?? false);

  Future<void> resolveFormatFromGguf(String modelSource) async {
    if (explicitFormat || ggufFormat != null) return;
    final metadata = await sniffGgufMetadata(modelSource);
    if (metadata == null) return;
    final detected = chatFormatFromGgufMetadata(metadata);
    final resolved = detected == null
        ? null
        : llama.resolveChatFormat(detected);
    if (resolved == null) {
      developer.log(
        'GGUF metadata gave no usable chat format for $modelSource '
        '(architecture: ${metadata.architecture}, name: ${metadata.name}); '
        'keeping the name-based guess.',
        name: 'local_llama',
      );
      return;
    }
    ggufFormat = resolved;
    _resolvedLlamaFormats[loadKey] = resolved;
    developer.log(
      'Chat format "$detected" resolved from GGUF metadata for '
      '${metadata.name ?? modelSource}.',
      name: 'local_llama',
    );
  }

  // The host reuses the resident session on a matching key (no reload) and
  // otherwise disposes it before running this loader, so at most one local
  // model is ever loaded. The loader runs only on a miss, so its progress,
  // download, and format-sniff work is skipped when the model is reused.
  Future<llama.LlamaSession> loader(llama.LlamaRuntime runtime) async {
    try {
      final llama.LlamaSession loaded;
      // A fresh load re-plans from scratch; a stale entry from an earlier
      // residency must not describe a session it no longer matches.
      _plannedLocalContextTokens.remove(loadKey);
      final selectedLocalPath = location.localPath;
      if (selectedLocalPath != null) {
        _localLlamaProgress.update(
          model.id,
          const _LocalLlamaStatus(
            phase: _LocalLlamaPhase.loading,
            message: 'Loading selected local model...',
          ),
        );
        await resolveFormatFromGguf(selectedLocalPath);
        loaded = await runtime.loadModel(
          await _memoryPlannedLocalSpec(
            spec,
            loadKey: loadKey,
            modelId: model.id,
            modelPath: selectedLocalPath,
            mmprojPath: location.mmprojLocalPath,
            draftPath: location.draftLocalPath,
          ),
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
        await resolveFormatFromGguf(location.modelUrl.toString());
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
        await resolveFormatFromGguf(paths.modelPath);
        loaded = await runtime.loadModel(
          await _memoryPlannedLocalSpec(
            spec,
            loadKey: loadKey,
            modelId: model.id,
            modelPath: paths.modelPath,
            mmprojPath: paths.mmprojPath,
            draftPath: paths.draftPath,
          ),
          localPath: paths.modelPath,
          localMmprojPath: paths.mmprojPath,
          localDraftPath: paths.draftPath,
        );
      }
      final plannedTokens = _plannedLocalContextTokens[loadKey];
      final contextNote = plannedTokens == null
          ? ''
          : ' Context sized to $plannedTokens of the configured '
                '${spec.contextSize} tokens for available memory.';
      _localLlamaProgress.update(
        model.id,
        _LocalLlamaStatus(
          phase: _LocalLlamaPhase.ready,
          message: runtime.supportsMultiThreading
              ? 'Local model ready.$contextNote'
              : 'Local model ready (single-threaded: this page is not '
                    'cross-origin isolated, so larger models may take '
                    'minutes per reply — reload once so the isolation '
                    'service worker can enable multithreading).'
                    '$contextNote',
          progress: 1,
        ),
      );
      return loaded;
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
  }

  // KV ownership: each conversation (delegates included, via their derived
  // scope ids) keeps its own KV-cache lineage in the shared session, so
  // returning to a warm chat restores its prefix instead of re-prefilling.
  // Title generation and scope-less internal callers are transient owners:
  // they may use sequence 0 for their one-shot work, but their state is
  // never stashed and they never collide with a conversation's owner key.
  final String kvOwnerKey;
  final bool retainKvState;
  if (forTitle) {
    kvOwnerKey = 'background:title';
    retainKvState = false;
  } else if (scope != null) {
    kvOwnerKey = 'conversation:${scope.conversationId}';
    retainKvState = true;
  } else {
    kvOwnerKey = 'internal:${_internalLocalOwnerSeq++}';
    retainKvState = false;
  }

  final thinking = services.getService<ThinkingSettings>();
  ai.ChatClient buildSessionClient(llama.LlamaSession session) =>
      llama.createLlamaChatClient(
        spec: spec,
        // Evaluated per request: when the loader shrank the context to fit
        // memory, prompt budgeting must target what the session actually
        // allocated, not the configured maximum.
        contextSizeOverride: _plannedLocalContextTokens[loadKey],
        sessionProvider: () async => session,
        // On a session cache hit this client's loader never runs, so read a
        // format recorded by whichever client first loaded this model before
        // falling back to the spec's file-name guess.
        formatResolver: () => ggufFormat ?? _resolvedLlamaFormats[loadKey],
        inspector: forTitle
            ? null
            : services.getService<llama.PromptInspector>(),
        // Evaluated per request, so the chat toggle applies
        // mid-conversation. Title generation forces thinking off: a
        // reasoning block would consume the tiny output budget and leave no
        // room for the title itself.
        isThinkingEnabled: forTitle
            ? () => false
            : () => thinking?.enabledFor(model.id) ?? spec.enableThinking,
      );

  return LeasedLocalLlamaChatClient(
    host: host,
    loadKey: loadKey,
    ownerKey: kvOwnerKey,
    retainKvState: retainKvState,
    // Background titling must never trigger a load or eviction: a null
    // loader makes every lease resident-only, so it throws instead of
    // reloading when the resident model changed out from under it (e.g. a
    // scheduled task swapped models) — the summarizer catches this and
    // moves on.
    load: forTitle ? null : loader,
    buildClient: buildSessionClient,
  );
}

/// Applies memory-aware context sizing to [spec] before a native load.
///
/// The configured `llama.contextSize` is the desired maximum; the returned
/// spec carries the largest context that fits the device's current memory
/// budget (see [planLocalLlamaContext]). Shrunk sizes are recorded in
/// [_plannedLocalContextTokens] under [loadKey] so chat clients budget
/// prompts against the real allocation.
///
/// Best-effort by design: when the GGUF header lacks the needed
/// hyperparameters or the platform has no honest memory measurements
/// (web, non-Apple native), [spec] loads unchanged — exactly today's
/// behavior.
Future<llama.ModelSpec> _memoryPlannedLocalSpec(
  llama.ModelSpec spec, {
  required String loadKey,
  required String modelId,
  required String modelPath,
  String? mmprojPath,
  String? draftPath,
}) async {
  final estimate = await readLocalLlamaMemoryEstimate(
    modelPath: modelPath,
    mmprojPath: mmprojPath,
    draftPath: draftPath,
  );
  if (estimate == null) return spec;
  final memory = await llama.createSystemMemoryMonitor().sample();
  // Fixed fallback numbers (4 GB assumed) would mis-size real machines in
  // both directions; only plan against actual measurements.
  if (memory.isEstimated) return spec;

  final plan = planLocalLlamaContext(
    estimate: estimate,
    memory: memory,
    desiredContextTokens: spec.contextSize,
  );
  if (plan.memoryCritical) {
    developer.log(
      'Local model "$modelId" barely fits: a ${plan.contextTokens}-token '
      'context needs ~${estimate.bytesForContext(plan.contextTokens)} bytes '
      'with ${memory.availableBytes} available; loading at the floor '
      'anyway.',
      name: 'local_llama.memory',
      level: 900,
    );
  }
  if (!plan.isReduced) {
    developer.log(
      'Local model "$modelId" fits: keeping the configured '
      '${spec.contextSize}-token context '
      '(~${estimate.bytesForContext(plan.contextTokens)} bytes of '
      '${memory.availableBytes} available).',
      name: 'local_llama.memory',
    );
    return spec;
  }
  developer.log(
    'Context for "$modelId" sized to ${plan.contextTokens} of the '
    'configured ${spec.contextSize} tokens '
    '(~${estimate.bytesForContext(plan.contextTokens)} bytes of '
    '${memory.availableBytes} available, ${estimate.kvBytesPerToken} '
    'KV bytes/token).',
    name: 'local_llama.memory',
  );
  _plannedLocalContextTokens[loadKey] = plan.contextTokens;
  return spec.copyWith(contextSize: plan.contextTokens);
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
    contextSize: intSetting('llama.contextSize', 8192),
    gpuLayers: intSetting('llama.gpuLayers', 999),
    draftGpuLayers: intSetting('llama.draftGpuLayers', 999),
    maxDraftTokens: intSetting('llama.maxDraftTokens', 3),
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

class _AgentsAppState extends State<AgentsApp> with WidgetsBindingObserver {
  late final GoRouter _router;
  late final TaskSchedulerService _scheduler;
  late final AppActivityMonitor _activity;

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
    // Feed the idle monitor so the background title summarizer knows when the
    // user is active. Pointer events come through the root [Listener] in build.
    _activity = widget.services.getRequiredService<AppActivityMonitor>();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _scheduler.stop();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _activity.reportUserActivity();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activity.reportLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    final themeSettings = widget.services.getRequiredService<ThemeSettings>();
    void reportActivity(PointerEvent _) => _activity.reportUserActivity();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: reportActivity,
      onPointerSignal: reportActivity,
      onPointerHover: reportActivity,
      child: ListenableBuilder(
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
      toolActivity: _listenToolActivity(),
      activity: widget.services.getService<AppActivityMonitor>(),
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
        scope: AgentScope(
          conversationId: _conversationId,
          sessionIdResolver: () => _sessionId,
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

  /// Maps the durable transcript to displayable UI messages.
  ///
  /// Tool-call-only turns carry no text and are skipped; the model still
  /// sees them through the chat history provider. Loop-synthesized
  /// wait-for-background-agents feedback is model plumbing, not user input,
  /// so it is hidden as well.
  Future<List<ChatMessage>> _loadDisplayHistory({String? sessionId}) async {
    final entries = await _transcripts!.load(_conversationId);
    final messages = <ChatMessage>[];
    // Usage from entries that are not displayed (tool-call-only assistant
    // messages) rolls forward onto the turn's final visible bubble, so
    // restored badges match what the live stream showed.
    ai.UsageDetails? pendingUsage;

    for (final entry in entries) {
      if (sessionId != null && entry.sessionId != sessionId) continue;
      if (entry.message.authorName == loopFeedbackAuthorName) continue;
      // A scheduled-task prompt reaches the model but is never shown: either
      // tagged with the task author name (hidden user message) or sent as a
      // system turn, which would otherwise render as an LLM bubble below.
      if (entry.message.authorName == taskPromptAuthorName) continue;
      if (entry.message.role == ai.ChatRole.system) continue;
      for (final content
          in entry.message.contents.whereType<ai.UsageContent>()) {
        (pendingUsage ??= ai.UsageDetails()).add(content.details);
      }
      if (entry.message.text.trim().isEmpty) continue;
      if (entry.message.role == ai.ChatRole.user) {
        messages.add(
          ChatMessage.user(
            entry.message.text,
            _displayAttachmentsFor(entry.message),
          ),
        );
      } else {
        messages.add(
          ChatMessage(
            origin: MessageOrigin.llm,
            text: entry.message.text,
            attachments: const [],
          )..usage = pendingUsage,
        );
        pendingUsage = null;
      }
    }
    return messages;
  }

  /// Rebuilds display attachments from a transcript message's file and link
  /// contents, so attachment chips survive a restart. The transcript stores
  /// attachments as agent-native content ([ai.DataContent]/[ai.UriContent]);
  /// text-file inlining happens below persistence, so the original bytes are
  /// still here.
  List<Attachment> _displayAttachmentsFor(ai.ChatMessage message) => [
    for (final content in message.contents)
      if (content case ai.DataContent(data: final bytes?))
        FileAttachment.fileOrImage(
          name: content.name ?? 'attachment',
          mimeType: content.mediaType ?? 'application/octet-stream',
          bytes: bytes,
        )
      else if (content case ai.UriContent(:final uri, :final mediaType))
        LinkAttachment(
          name: uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '$uri',
          url: uri,
          mimeType: mediaType,
        ),
  ];

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
    final messages = _toTranscriptMessages(provider.history);
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

  /// Converts the visible UI [history] to agent-native messages for durable
  /// storage. Empty-text placeholders are dropped to match what
  /// [_loadDisplayHistory] renders back on resume.
  List<ai.ChatMessage> _toTranscriptMessages(Iterable<ChatMessage> history) => [
    for (final message in history)
      if ((message.text ?? '').trim().isNotEmpty)
        ai.ChatMessage(
          role: message.origin.isUser
              ? ai.ChatRole.user
              : ai.ChatRole.assistant,
          contents: [
            ai.TextContent(message.text!),
            if (message.origin.isUser)
              for (final attachment in message.attachments)
                _toAgentAttachmentContent(attachment),
          ],
        ),
  ];

  /// Maps a UI [attachment] to the agent-native content the transcript stores,
  /// so [_displayAttachmentsFor] can rebuild the chip on resume.
  ai.AIContent _toAgentAttachmentContent(Attachment attachment) =>
      switch (attachment) {
        FileAttachment(
          name: final name,
          mimeType: final mimeType,
          bytes: final bytes,
        ) =>
          ai.DataContent(bytes, mediaType: mimeType, name: name),
        LinkAttachment(url: final url, mimeType: final mimeType) =>
          ai.UriContent(url, mediaType: mimeType),
      };

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
    unawaited(_agentChangesSub?.cancel());
    unawaited(_finishStateChangesBeforePop());
    _provider?.dispose();
    while (_toolActivityRefs > 0) {
      _releaseToolActivity();
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
    ({Widget? leading, double? leadingWidth}) leading,
  ) => Scaffold(
    appBar: AppBar(
      // Match the LlmChatView body (scheme.surface) so the chat window
      // reads as one continuous surface rather than a banded app bar.
      backgroundColor: Theme.of(context).colorScheme.surface,
      leadingWidth: leading.leadingWidth,
      leading: leading.leading,
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
            if (log == null) return const SizedBox.shrink();
            return IconButton(
              tooltip: 'Inspect prompts sent to models',
              icon: const Icon(LucideIcons.braces300),
              onPressed: () => showPromptInspector(context, log),
            );
          },
        ),
        if (!widget.isPrivate)
          Builder(
            builder: (context) {
              final usage = _usage;
              if (usage == null) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Token usage per model',
                icon: const Icon(LucideIcons.chartPie300),
                onPressed: () => showUsageStats(
                  context,
                  usage: usage,
                  conversationId: _conversationId,
                  currentSessionId: _sessionId,
                ),
              );
            },
          ),
        // Network chats stay single-session (their transcript is rewritten
        // whole from the live history), so the per-session view never applies.
        if (!widget.isPrivate && !_isNetworkAgent && _sessionList.length > 1)
          PopupMenuButton<String?>(
            tooltip: 'View a session',
            icon: Icon(
              LucideIcons.history300,
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
              // A new session re-stamps only new turns for local agents, but a
              // network chat rewrites its whole transcript under one session,
              // so segmenting it would strand the earlier turns. Keep remote
              // conversations single-session.
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
          ),
        Builder(
          builder: (context) {
            final panel = SidePanelScope.maybeOf(context);
            if (panel == null) return const SizedBox.shrink();
            return IconButton(
              tooltip: panel.isOpen ? 'Hide panel' : 'Show panel',
              icon: Icon(
                panel.isOpen
                    ? LucideIcons.panelRightClose300
                    : LucideIcons.panelRightOpen300,
              ),
              onPressed: () => panel.toggle(
                (context) => ChatSidePanel(onClose: panel.close),
              ),
            );
          },
        ),
      ],
    ),
    body: _buildChatBody(context),
  );

  Widget _buildChatBody(BuildContext context) =>
      FutureBuilder<AgentLlmProvider>(
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
                LucideIcons.circleAlert300,
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
                    icon: const Icon(LucideIcons.refreshCw300),
                    label: const Text('Retry'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.go('/settings/agents'),
                    icon: const Icon(LucideIcons.settings300),
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
        LucideIcons.brain300,
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
                          ? LucideIcons.circleAlert300
                          : LucideIcons.circleCheck300,
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

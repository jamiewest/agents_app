// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The local-llama agent factory: everything between a saved local-model
/// configuration and a runnable [ai.ChatClient] over the shared resident
/// model — load planning, artifact download, chat-format resolution,
/// memory-aware context sizing, warmup, and the load-progress registry the
/// chat UI's banner watches.
///
/// Extracted from `main.dart` as staging for the move into the
/// `agents_llama` repository (see the repo plan); nothing here depends on
/// widgets.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/chat.dart' as llama;
import 'package:llama_cpp_flutter/llama_cpp_flutter.dart' as llama;
import 'package:llama_cpp_flutter/orchestration.dart' as llama;
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';

import 'downloaded_artifact_presence.dart';
import 'local_model_registration.dart';
import 'downloaded_model_artifacts.dart';
import 'local_llama_context_planner.dart';
import 'local_llama_lease_client.dart';
import 'local_llama_model_host.dart';

enum LocalLlamaPhase { idle, downloading, loading, ready, error }

@immutable
class LocalLlamaStatus {
  const LocalLlamaStatus({
    required this.phase,
    required this.message,
    this.progress,
  });

  static const idle = LocalLlamaStatus(
    phase: LocalLlamaPhase.idle,
    message: '',
  );

  final LocalLlamaPhase phase;
  final String message;
  final double? progress;

  bool get isVisible => phase != LocalLlamaPhase.idle;
}

final class LocalLlamaProgressRegistry extends ChangeNotifier {
  final Map<String, LocalLlamaStatus> _statuses = {};
  final Map<String, Timer> _dismissTimers = {};

  // How long the "ready" banner lingers before it clears itself, long enough
  // to read the confirmation (and the web single-threaded warning) without
  // leaving the banner up for the whole chat session.
  static const _readyLinger = Duration(seconds: 6);

  LocalLlamaStatus statusFor(String modelId) =>
      _statuses[modelId] ?? LocalLlamaStatus.idle;

  void update(String modelId, LocalLlamaStatus status) {
    _dismissTimers.remove(modelId)?.cancel();
    _statuses[modelId] = status;
    if (status.phase == LocalLlamaPhase.ready) {
      _dismissTimers[modelId] = Timer(_readyLinger, () {
        _dismissTimers.remove(modelId);
        _statuses[modelId] = LocalLlamaStatus.idle;
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

final localLlamaProgress = LocalLlamaProgressRegistry();

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

/// Config behind each local-model load key, so the title summarizer can
/// rebuild a client for whatever model [LocalLlamaModelHost] currently holds
/// and reuse its session through an acquire cache hit.
///
/// An entry is written when a load key is *planned*, which can precede — or
/// never reach — residency: a declined warm-up leaves one behind for a model
/// that never loaded. That is safe because the only reader
/// ([residentLocalTitleClient]) looks up by [LocalLlamaModelHost.currentKey], so
/// it can only ever reach the entry of a model that really is resident.
final Map<String, ({ModelSourceConfig source, ModelConfig model})>
_residentLocalConfigs = {};

/// A chat client bound to the resident local model, or null when none is
/// loaded. Reuses the resident session with no load and no eviction by asking
/// [createLocalLlamaClient] for exactly the resident load key.
ai.ChatClient? residentLocalTitleClient(ServiceProvider services) {
  final host = services.getRequiredService<LocalLlamaModelHost>();
  final key = host.currentKey;
  if (key == null) return null;
  final config = _residentLocalConfigs[key];
  if (config == null) return null;
  return createLocalLlamaClient(
    services,
    source: config.source,
    model: config.model,
    forTitle: true,
  );
}

/// Monotonic id for scope-less local clients, so unrelated internal calls
/// never share a KV owner key accidentally.
int _internalLocalOwnerSeq = 0;

/// Resolves a residency miss on the shared llama runtime.
typedef _LocalLlamaLoader =
    Future<llama.LlamaSession> Function(llama.LlamaRuntime runtime);

/// Everything needed to make one local model resident, with no opinion about
/// what will then use it.
///
/// Shared by [createLocalLlamaClient] and [warmLocalLlamaModel] so a chat
/// request and a background warm-up derive the *same* [loadKey] and run the
/// *same* [loader]. A warm-up that computed either differently would load a
/// second copy — evicting the first — instead of priming the one the next
/// chat asks for.
@immutable
class _LocalLlamaLoadPlan {
  const _LocalLlamaLoadPlan({
    required this.host,
    required this.spec,
    required this.location,
    required this.loadKey,
    required this.loader,
  });

  /// Holds the single resident model this plan loads into.
  final LocalLlamaModelHost host;

  /// The model's load parameters, before memory-aware context planning.
  final llama.ModelSpec spec;

  /// Where the model's artifacts come from: a picked file or a URL.
  final _LocalLlamaModelLocation location;

  /// Identifies the model, its artifacts, and its load parameters, so the
  /// host reuses the resident session when another agent shares the same
  /// local model and reloads only when the model actually differs.
  final String loadKey;

  /// Loads the model. Runs only on a residency miss.
  final _LocalLlamaLoader loader;
}

_LocalLlamaLoadPlan _localLlamaLoadPlan(
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
  final host = services.getRequiredService<LocalLlamaModelHost>();

  // See [_LocalLlamaLoadPlan.loadKey].
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

  // Format chosen from the GGUF's own metadata during load, recorded in
  // [_resolvedLlamaFormats] under this load key. The embedded chat template
  // is what the model was actually trained on, so it beats the file-name
  // guess baked into the spec; an explicit chat.format setting still beats
  // both. The map is the only channel: whoever loads the model — a chat
  // client or a background warm-up — records the format there for every
  // later client that reuses the resident session.
  final explicitFormat =
      (model.settings[chatFormatSetting]?.trim().isNotEmpty ?? false) ||
      (model.settings[legacyLlamaFormatSetting]?.trim().isNotEmpty ?? false);

  Future<void> resolveFormatFromGguf(String modelSource) async {
    if (explicitFormat || _resolvedLlamaFormats[loadKey] != null) return;
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
        localLlamaProgress.update(
          model.id,
          const LocalLlamaStatus(
            phase: LocalLlamaPhase.loading,
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
        localLlamaProgress.update(
          model.id,
          LocalLlamaStatus(
            phase: LocalLlamaPhase.loading,
            message: location.isSelectedFile
                ? 'Loading selected local model...'
                : 'Loading local model from browser cache...',
          ),
        );
        await resolveFormatFromGguf(location.modelUrl.toString());
        loaded = await runtime.loadModel(
          spec,
          onProgress: (progress) {
            localLlamaProgress.update(
              model.id,
              LocalLlamaStatus(
                phase: LocalLlamaPhase.downloading,
                message: 'Downloading local model to browser cache...',
                progress: progress.clamp(0, 1).toDouble(),
              ),
            );
          },
        );
      } else {
        final paths = await _downloadLocalModel(services, spec, model.id);
        localLlamaProgress.update(
          model.id,
          const LocalLlamaStatus(
            phase: LocalLlamaPhase.loading,
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
      localLlamaProgress.update(
        model.id,
        LocalLlamaStatus(
          phase: LocalLlamaPhase.ready,
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
      localLlamaProgress.update(
        model.id,
        LocalLlamaStatus(
          phase: LocalLlamaPhase.error,
          message: 'Local model failed: $error',
        ),
      );
      rethrow;
    }
  }

  return _LocalLlamaLoadPlan(
    host: host,
    spec: spec,
    location: location,
    loadKey: loadKey,
    loader: loader,
  );
}

ai.ChatClient createLocalLlamaClient(
  ServiceProvider services, {
  required ModelSourceConfig source,
  required ModelConfig model,
  AgentScope? scope,
  bool forTitle = false,
}) {
  final plan = _localLlamaLoadPlan(services, source: source, model: model);
  final loadKey = plan.loadKey;
  final spec = plan.spec;

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
        // On a session cache hit no loader runs for this client at all, so
        // read the format recorded by whoever first loaded this model —
        // another chat client or the startup warm-up — and fall back to the
        // spec's file-name guess when nothing sniffed it.
        formatResolver: () => _resolvedLlamaFormats[loadKey],
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
    host: plan.host,
    loadKey: loadKey,
    ownerKey: kvOwnerKey,
    retainKvState: retainKvState,
    // Background titling must never trigger a load or eviction: a null
    // loader makes every lease resident-only, so it throws instead of
    // reloading when the resident model changed out from under it (e.g. a
    // scheduled task swapped models) — the summarizer catches this and
    // moves on.
    load: forTitle ? null : plan.loader,
    buildClient: buildSessionClient,
  );
}

/// Makes [model] resident ahead of the first message, when doing so costs
/// nothing but time already available.
///
/// Uses [LocalLlamaModelHost.acquire] rather than a lease: residency is all
/// that is wanted, and acquire grants no exclusivity and performs no KV owner
/// switch, so it neither reserves the model from a real request nor disturbs
/// any conversation's cached prefix. A user message that arrives mid-load
/// queues on the host's gate and then takes the session as a cache hit — it
/// never starts a second load, so the worst case of warming is the same wait
/// the user would have had anyway.
///
/// Warms only what is already downloaded. The loader fetches whatever is
/// missing, so warming an undownloaded model would pull gigabytes at
/// launch that the user never asked for; that case is left to the first
/// message, where the progress banner explains the wait. Returns whether the
/// model was warmed.
Future<bool> warmLocalLlamaModel(
  ServiceProvider services, {
  required ModelSourceConfig source,
  required ModelConfig model,
}) async {
  // A model whose picked file needs reselecting throws from here; that is a
  // configuration problem for the first real request to report, not
  // something a silent warm-up should surface.
  final plan = _localLlamaLoadPlan(services, source: source, model: model);
  // Something already beat the warm-up to the single resident slot. Nothing
  // to gain, and this way the warm-up can never be the reason a model the
  // user is talking to gets evicted.
  if (plan.host.currentKey != null) return false;
  if (plan.location.localPath == null &&
      !await _localArtifactsAlreadyDownloaded(services, plan.spec, model.id)) {
    developer.log(
      'Skipping warm-up of "${model.label}": its artifacts are not '
      'downloaded yet, and warming would start the download.',
      name: 'local_llama.warmup',
    );
    return false;
  }
  await plan.host.acquire(plan.loadKey, plan.loader);
  return true;
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

/// One downloadable artifact of a local model.
typedef _LocalArtifactSource = ({
  Uri url,
  String fallbackFilename,
  String label,
});

/// The remote artifacts [spec] declares, in load order.
///
/// The single source of truth for each artifact's URL, on-disk name, and
/// progress label, so the downloader and the warm-up's "is this already on
/// disk?" probe can never disagree about where a file lives — a divergence
/// there would make the probe check the wrong path and silently never warm.
Map<LlamaArtifactKind, _LocalArtifactSource> _localArtifactSources(
  llama.ModelSpec spec,
  String modelId,
) {
  final mmprojUrl = spec.mmprojUrl;
  final draftUrl = spec.draftUrl;
  return <LlamaArtifactKind, _LocalArtifactSource>{
    LlamaArtifactKind.model: (
      url: spec.modelUrl,
      fallbackFilename: '$modelId.gguf',
      label: 'local model',
    ),
    if (mmprojUrl != null)
      LlamaArtifactKind.mmproj: (
        url: mmprojUrl,
        fallbackFilename: '$modelId-mmproj.gguf',
        label: 'projector (mmproj)',
      ),
    if (draftUrl != null)
      LlamaArtifactKind.draft: (
        url: draftUrl,
        fallbackFilename: '$modelId-draft.gguf',
        label: 'draft/MTP model',
      ),
  };
}

DownloadRequest _localArtifactRequest(
  llama.ModelSpec spec,
  String modelId,
  _LocalArtifactSource artifact,
) => DownloadRequest(
  url: artifact.url.toString(),
  filename: artifact.url.pathSegments.isEmpty
      ? artifact.fallbackFilename
      : artifact.url.pathSegments.last,
  directory: 'local_llama/$modelId',
  metaData: spec.id,
);

/// Whether every artifact [spec] declares is already on disk.
///
/// Answers "would making this model resident be free?" — the gate the
/// startup warm-up needs, since the loader downloads whatever artifact is
/// not yet on disk. Reached only by URL-backed models; a picked file
/// is already local. On web the probe asks the runtime's managed OPFS
/// storage instead of the filesystem; models small enough to live in
/// wllama's own URL cache stay invisible there and report absent (see
/// [downloadedArtifactsInManagedStorage]).
Future<bool> _localArtifactsAlreadyDownloaded(
  ServiceProvider services,
  llama.ModelSpec spec,
  String modelId,
) async {
  if (kIsWeb) {
    return downloadedArtifactsInManagedStorage([
      for (final artifact in _localArtifactSources(spec, modelId).values)
        artifact.url,
    ]);
  }
  final downloads = services.getRequiredService<DownloadService>();
  for (final artifact in _localArtifactSources(spec, modelId).values) {
    final path = await downloads.filePathFor(
      _localArtifactRequest(spec, modelId, artifact),
    );
    if (!await downloadedArtifactExists(path)) return false;
  }
  return true;
}

Future<({String modelPath, String? mmprojPath, String? draftPath})>
_downloadLocalModel(
  ServiceProvider services,
  llama.ModelSpec spec,
  String modelId,
) async {
  final downloads = services.getRequiredService<DownloadService>();
  final paths = <LlamaArtifactKind, String>{};
  // Insertion-ordered, so the main model still downloads before its optional
  // companions.
  for (final entry in _localArtifactSources(spec, modelId).entries) {
    paths[entry.key] = await _downloadLocalArtifact(
      downloads,
      spec,
      modelId,
      entry.value,
    );
  }
  return (
    modelPath: paths[LlamaArtifactKind.model]!,
    mmprojPath: paths[LlamaArtifactKind.mmproj],
    draftPath: paths[LlamaArtifactKind.draft],
  );
}

Future<String> _downloadLocalArtifact(
  DownloadService downloads,
  llama.ModelSpec spec,
  String modelId,
  _LocalArtifactSource artifact,
) async {
  final label = artifact.label;
  final request = _localArtifactRequest(spec, modelId, artifact);
  final path = await downloads.filePathFor(request);
  // A non-empty file at the final path is a completed download: the plugin
  // transfers into a temporary location and only moves the file here on
  // success. Without this check every fresh app process re-downloaded the
  // artifact from its URL, because the loader only runs on a resident-session
  // miss — never within a run, always after a restart.
  if (await downloadedArtifactExists(path)) return path;
  localLlamaProgress.update(
    modelId,
    LocalLlamaStatus(
      phase: LocalLlamaPhase.downloading,
      message: 'Downloading $label...',
      progress: 0,
    ),
  );
  final status = await downloads.download(
    request,
    onProgress: (progress) {
      localLlamaProgress.update(
        modelId,
        LocalLlamaStatus(
          phase: LocalLlamaPhase.downloading,
          message: 'Downloading $label...',
          progress: progress.clamp(0, 1),
        ),
      );
    },
    onStatus: (status) {
      if (status == DownloadStatus.running) {
        localLlamaProgress.update(
          modelId,
          LocalLlamaStatus(
            phase: LocalLlamaPhase.downloading,
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

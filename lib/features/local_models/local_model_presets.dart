// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:universal_platform/universal_platform.dart';

/// A known-good local GGUF model with sensible runtime defaults.
///
/// A preset pins every artifact a model needs — main GGUF, vision
/// projector (mmproj), and speculative-decoding drafter (MTP) — as one
/// unit, because the files are not mix-and-match: an mmproj built for one
/// model size projects to the wrong embedding width on another (verified
/// by reading the GGUF headers: Gemma 4 E4B's projector outputs 2560-wide
/// embeddings, E2B's 1536), and an MTP drafter reads the target model's
/// hidden state, so it only works with the exact model it was trained
/// against.
class LocalModelPreset {
  /// Creates a [LocalModelPreset].
  const LocalModelPreset({
    required this.name,
    required this.subtitle,
    required this.url,
    required this.contextSize,
    required this.minMemoryMb,
    this.mmprojUrl,
    this.draftModelUrl,
    this.chatFormat,
    this.supportsThinking = false,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.webCompatible = true,
  });

  /// Display name.
  final String name;

  /// One-line guidance (size/quantization/memory).
  final String subtitle;

  /// Direct GGUF download URL (Hugging Face resolve link).
  ///
  /// Pinned to a commit SHA rather than `main`. A shipped build cannot be
  /// re-pointed, so a mutable ref means an upstream rename breaks the
  /// download for everyone already on that version — which is exactly how
  /// the E4B drafter link rotted before it was caught. Re-resolve the SHA
  /// deliberately when moving a preset to a newer upload:
  ///
  /// ```bash
  /// curl -s https://huggingface.co/api/models/<org>/<repo> | jq -r .sha
  /// ```
  final String url;

  /// Vision projector (mmproj) GGUF URL, from the same repo as [url].
  ///
  /// Must match the exact model size/variant — see the class doc.
  final String? mmprojUrl;

  /// Speculative-decoding draft (MTP) GGUF URL for this exact model.
  final String? draftModelUrl;

  /// Explicit `chat.format` name, bypassing file-name detection.
  ///
  /// Set for presets whose trio must never be re-interpreted (the
  /// detection heuristics only pre-fill; this always wins).
  final String? chatFormat;

  /// Default context window to configure.
  final int contextSize;

  /// Rough minimum device memory in megabytes.
  final int minMemoryMb;

  /// Whether the model supports extended reasoning.
  final bool supportsThinking;

  /// Whether the model accepts image input (requires [mmprojUrl]).
  final bool supportsVision;

  /// Whether the model accepts audio input (requires an [mmprojUrl] whose
  /// projector carries an audio encoder; the runtime re-checks with
  /// `mtmd_support_audio` and fails audio turns when it does not).
  final bool supportsAudio;

  /// Whether the preset can load in the web runtime.
  ///
  /// `false` hides it from the browser's preset list. Set it for desktop
  /// presets that cannot load there — a [draftModelUrl] makes the web
  /// runtime throw (wllama cannot stage a second GGUF for
  /// `spec_draft_model`) — or that are sized for desktop memory a wasm32
  /// heap (4 GiB address space) cannot hold.
  final bool webCompatible;

  /// Materializes the preset as a new [ModelConfig] for [sourceId].
  ///
  /// When [chatFormat] is unset the runtime auto-detects the format from
  /// the file name.
  ModelConfig toModelConfig({required String id, required String sourceId}) =>
      ModelConfig(
        id: id,
        sourceId: sourceId,
        modelId: name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'),
        displayName: name,
        settings: {
          'llama.modelUrl': url,
          'llama.mmprojUrl': ?mmprojUrl,
          'llama.draftModelUrl': ?draftModelUrl,
          chatFormatSetting: ?chatFormat,
          'llama.contextSize': '$contextSize',
          ModelCapabilities.contextLengthKey: '$contextSize',
          ModelCapabilities.minMemoryMbKey: '$minMemoryMb',
          if (supportsThinking) ModelCapabilities.thinkingKey: 'true',
          if (supportsVision) ModelCapabilities.visionKey: 'true',
          if (supportsAudio) ModelCapabilities.audioKey: 'true',
        },
      );
}

/// Curated presets to reduce local-model setup friction.
///
/// All are small instruction-tuned GGUFs that run on consumer hardware;
/// quantization and memory notes are in each subtitle.
const List<LocalModelPreset> localModelPresets = [
  LocalModelPreset(
    name: 'Gemma 3 1B',
    subtitle: 'Q4_0 QAT · ~0.7 GB file · fine on 4 GB RAM · fastest',
    // lmstudio-community mirrors Google's QAT quant without the license
    // gate; the google/ repos answer 401 to unauthenticated downloads,
    // which is every in-app download.
    url:
        'https://huggingface.co/lmstudio-community/gemma-3-1B-it-qat-GGUF/'
        'resolve/c8ffb6497c1f3d54cb012c85b5ef3901fe6878e7/'
        'gemma-3-1B-it-QAT-Q4_0.gguf',
    // 8192 so the harness system prompt + tool declarations (~5k tokens) fit;
    // 4096 overflowed and stalled prefill.
    contextSize: 8192,
    minMemoryMb: 4096,
  ),
  LocalModelPreset(
    name: 'Gemma 3 4B',
    subtitle: 'Q4_0 QAT · ~2.5 GB file · 8 GB RAM · good quality',
    url:
        'https://huggingface.co/lmstudio-community/gemma-3-4B-it-qat-GGUF/'
        'resolve/34701dc3de023d018ac5cc78e8b1af773cdf9936/'
        'gemma-3-4B-it-QAT-Q4_0.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
  ),
  LocalModelPreset(
    name: 'Qwen3 4B',
    subtitle: 'Q4_K_M · ~2.5 GB file · 8 GB RAM · supports thinking',
    url:
        'https://huggingface.co/Qwen/Qwen3-4B-GGUF/'
        'resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/'
        'Qwen3-4B-Q4_K_M.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
    supportsThinking: true,
  ),
  LocalModelPreset(
    name: 'Llama 3.2 3B',
    subtitle: 'Q4_K_M · ~2 GB file · 8 GB RAM · balanced',
    url:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/'
        'resolve/5ab33fa94d1d04e903623ae72c95d1696f09f9e8/'
        'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
  ),
  // Gemma 4 E2B, the browser-viable Gemma 4: per-layer embeddings keep the
  // effective parameter count at 2.3B, and the QAT UD-Q4_K_XL file is
  // 2.62 GB — over the 2 GiB wasm32 per-file limit (the web runtime's
  // OPFS client-side split handles that) but small enough that weights
  // plus an 8k q8_0 KV cache fit the 4 GiB wasm address space.
  // Deliberately text-only and drafter-free: the QAT repo ships no
  // projector (and E2B's 1536-wide projection would need its own anyway;
  // see the class doc), and an MTP drafter would make the web runtime
  // throw. Fine on desktop too, where the E4B preset below is the richer
  // choice.
  LocalModelPreset(
    name: 'Gemma 4 E2B',
    subtitle:
        'Q4_K_XL QAT · ~2.6 GB file · 8 GB RAM · thinking · '
        'runs in the browser',
    url:
        'https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/'
        'resolve/66a399f68ddd113b06dff02fca9523e55465d11d/'
        'gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf',
    chatFormat: 'gemma',
    contextSize: 8192,
    minMemoryMb: 8192,
    supportsThinking: true,
  ),
  // Gemma 4 E4B for Macs. Every artifact comes from the E4B repo: the
  // E2B repo's mmproj is NOT compatible (1536- vs 2560-wide projection;
  // see the class doc), and the MTP drafter is E4B-specific. The Q4_0
  // drafter beats Q8_0 on Metal (measured 2026-06-11 on an M1: ~19.4
  // tok/s at 0.42 acceptance vs ~8.7 tok/s at 0.21). The drafter is
  // desktop-only knowledge: on 8 GB phones the MTP verification batch
  // fails to decode, so don't copy this preset to a mobile default
  // as-is. 16k context ≈ 0.9 GB KV; UD-Q4_K_XL has no ternary tensors,
  // so all layers run on Metal.
  LocalModelPreset(
    name: 'Gemma 4 E4B (Mac)',
    subtitle:
        'Q4_K_XL QAT · ~4.2 GB + 1 GB projector + MTP drafter · 16 GB RAM · '
        'vision + audio + thinking + speculative decoding, all-Metal',
    url:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/8c5a9e4fd5482e2be20fe0bf013b4c262a8f4265/'
        'gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf',
    mmprojUrl:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/8c5a9e4fd5482e2be20fe0bf013b4c262a8f4265/'
        'mmproj-F16.gguf',
    draftModelUrl:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/8c5a9e4fd5482e2be20fe0bf013b4c262a8f4265/'
        'MTP/mtp-gemma-4-E4B-it-Q4_0.gguf',
    chatFormat: 'gemma',
    contextSize: 16384,
    minMemoryMb: 16384,
    supportsThinking: true,
    supportsVision: true,
    supportsAudio: true,
    webCompatible: false,
  ),
  // LFM2.5 VL for Macs. Q8_0 over Q4_0: at 1.6B the extra ~0.5 GB is
  // cheap on a desktop and the quant quality gap matters more on small
  // models. The mmproj file name really is lowercase "1.6b" upstream.
  // No MTP drafter exists for this family. The explicit chat format
  // pins LFM2.5's plain-JSON tool style (the `lfm2` tagged style is a
  // different dialect the file-name heuristics must never fall back
  // to).
  LocalModelPreset(
    name: 'LFM2.5 VL 1.6B (Mac)',
    subtitle: 'Q8_0 · ~1.2 GB + 0.8 GB vision · 8 GB RAM · fast vision model',
    url:
        'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/'
        'resolve/0df8719db7180cedababc2bc589abfe5e8ebcd1f/'
        'LFM2.5-VL-1.6B-Q8_0.gguf',
    mmprojUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/'
        'resolve/0df8719db7180cedababc2bc589abfe5e8ebcd1f/'
        'mmproj-LFM2.5-VL-1.6b-F16.gguf',
    chatFormat: 'lfm2.5-vl',
    contextSize: 16384,
    minMemoryMb: 8192,
    supportsVision: true,
    webCompatible: false,
  ),
];

/// The presets offered on the current device.
///
/// The browser drops the Mac-tuned presets ([LocalModelPreset.webCompatible]
/// explains why), and phones drop them for the same underlying reasons: the
/// artifacts that rule out the web runtime — MTP drafters, desktop-sized
/// downloads — fail or thrash on mobile hardware too. Only desktops see the
/// full list.
///
/// [totalMemoryMb] is the device's physical memory when an exact measurement
/// exists, or null when it is unknown or estimated. Presets whose
/// [LocalModelPreset.minMemoryMb] exceeds it are dropped, with half a
/// gigabyte of slack because reported totals land just under the marketing
/// size. Null never empties the list — unknown memory skips the filter
/// rather than hiding models a machine might well hold.
List<LocalModelPreset> presetsFor({int? totalMemoryMb}) => [
  for (final preset in localModelPresets)
    if ((preset.webCompatible || UniversalPlatform.isDesktop) &&
        (totalMemoryMb == null || totalMemoryMb + 512 >= preset.minMemoryMb))
      preset,
];

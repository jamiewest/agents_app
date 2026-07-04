// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

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
  });

  /// Display name.
  final String name;

  /// One-line guidance (size/quantization/memory).
  final String subtitle;

  /// Direct GGUF download URL (Hugging Face resolve link).
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
    url:
        'https://huggingface.co/google/gemma-3-1b-it-qat-q4_0-gguf/'
        'resolve/main/gemma-3-1b-it-q4_0.gguf',
    // 8192 so the harness system prompt + tool declarations (~5k tokens) fit;
    // 4096 overflowed and stalled prefill.
    contextSize: 8192,
    minMemoryMb: 4096,
  ),
  LocalModelPreset(
    name: 'Gemma 3 4B',
    subtitle: 'Q4_0 QAT · ~2.5 GB file · 8 GB RAM · good quality',
    url:
        'https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf/'
        'resolve/main/gemma-3-4b-it-q4_0.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
  ),
  LocalModelPreset(
    name: 'Qwen3 4B',
    subtitle: 'Q4_K_M · ~2.5 GB file · 8 GB RAM · supports thinking',
    url:
        'https://huggingface.co/Qwen/Qwen3-4B-GGUF/'
        'resolve/main/Qwen3-4B-Q4_K_M.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
    supportsThinking: true,
  ),
  LocalModelPreset(
    name: 'Llama 3.2 3B',
    subtitle: 'Q4_K_M · ~2 GB file · 8 GB RAM · balanced',
    url:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/'
        'resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    contextSize: 8192,
    minMemoryMb: 8192,
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
        'Q4_K_XL QAT · ~4.2 GB + 1 GB vision + MTP drafter · 16 GB RAM · '
        'vision + speculative decoding, all-Metal',
    url:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf',
    mmprojUrl:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/mmproj-F16.gguf',
    draftModelUrl:
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/MTP/gemma-4-E4B-it-Q4_0-MTP.gguf',
    chatFormat: 'gemma',
    contextSize: 16384,
    minMemoryMb: 16384,
    supportsVision: true,
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
        'resolve/main/LFM2.5-VL-1.6B-Q8_0.gguf',
    mmprojUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/'
        'resolve/main/mmproj-LFM2.5-VL-1.6b-F16.gguf',
    chatFormat: 'lfm2.5-vl',
    contextSize: 16384,
    minMemoryMb: 8192,
    supportsVision: true,
  ),
];

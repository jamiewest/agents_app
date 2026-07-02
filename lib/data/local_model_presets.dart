// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

/// A known-good local GGUF model with sensible runtime defaults.
class LocalModelPreset {
  /// Creates a [LocalModelPreset].
  const LocalModelPreset({
    required this.name,
    required this.subtitle,
    required this.url,
    required this.contextSize,
    required this.minMemoryMb,
    this.supportsThinking = false,
  });

  /// Display name.
  final String name;

  /// One-line guidance (size/quantization/memory).
  final String subtitle;

  /// Direct GGUF download URL (Hugging Face resolve link).
  final String url;

  /// Default context window to configure.
  final int contextSize;

  /// Rough minimum device memory in megabytes.
  final int minMemoryMb;

  /// Whether the model supports extended reasoning.
  final bool supportsThinking;

  /// Materializes the preset as a new [ModelConfig] for [sourceId].
  ///
  /// The chat format is left unset so the runtime auto-detects it from the
  /// file name.
  ModelConfig toModelConfig({required String id, required String sourceId}) =>
      ModelConfig(
        id: id,
        sourceId: sourceId,
        modelId: name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'),
        displayName: name,
        settings: {
          'llama.modelUrl': url,
          'llama.contextSize': '$contextSize',
          ModelCapabilities.contextLengthKey: '$contextSize',
          ModelCapabilities.minMemoryMbKey: '$minMemoryMb',
          if (supportsThinking) ModelCapabilities.thinkingKey: 'true',
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
    contextSize: 4096,
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
];

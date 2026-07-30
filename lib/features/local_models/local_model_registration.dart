// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Runtime registry of locally picked GGUF files per model.
///
/// Hoisted out of the model editor widget so the local-llama agent factory
/// (data layer) never depends on UI code. The editor registers selections;
/// the factory and bootstrap read them.
library;

/// The role a locally selected GGUF file plays for a local llama model.
enum LlamaArtifactKind {
  /// The main model weights.
  model,

  /// The optional multimodal projector (mmproj) enabling image input.
  mmproj,

  /// The optional speculative-decoding draft/MTP model.
  draft,
}

final Map<String, Map<LlamaArtifactKind, String>> _selectedLlamaModelFilePaths =
    {};

/// Registers a runtime-only local llama file selection for [kind].
void registerSelectedLlamaModelFile(
  String modelId,
  String path, {
  LlamaArtifactKind kind = LlamaArtifactKind.model,
}) {
  (_selectedLlamaModelFilePaths[modelId] ??= {})[kind] = path;
}

/// Returns the runtime-only selected file path of [kind] for [modelId].
String? selectedLlamaModelFilePathFor(
  String modelId, {
  LlamaArtifactKind kind = LlamaArtifactKind.model,
}) => _selectedLlamaModelFilePaths[modelId]?[kind];

/// Clears runtime-only selected file paths for [modelId]: the one for
/// [kind], or every artifact when [kind] is null.
void clearSelectedLlamaModelFile(String modelId, {LlamaArtifactKind? kind}) {
  if (kind == null) {
    _selectedLlamaModelFilePaths.remove(modelId);
    return;
  }
  final paths = _selectedLlamaModelFilePaths[modelId];
  paths?.remove(kind);
  if (paths != null && paths.isEmpty) {
    _selectedLlamaModelFilePaths.remove(modelId);
  }
}

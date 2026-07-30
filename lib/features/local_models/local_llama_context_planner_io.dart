/// Native implementation of the local-model memory estimate reader.
library;

import 'dart:io';

import 'package:llama_cpp_flutter/gguf.dart';
import 'package:llama_cpp_flutter/orchestration.dart';

/// Builds a [ModelMemoryEstimate] for the GGUF at [modelPath].
///
/// The projector file's bytes are folded into the weight cost:
/// [estimateModelMemory] has no mmproj parameter, but projector weights are
/// just as resident as the model's — ignoring them undercounts multimodal
/// presets by the better part of a gigabyte.
///
/// Best-effort: any read or parse problem (missing file, non-GGUF bytes, a
/// header without the needed hyperparameters) returns null, and the caller
/// loads with the configured context size as before.
Future<ModelMemoryEstimate?> readLocalLlamaMemoryEstimate({
  required String modelPath,
  String? mmprojPath,
  String? draftPath,
}) async {
  try {
    final architectureResult = await readGgufMetadataFile(
      modelPath,
      keys: {ggufArchitectureKey},
    );
    if (architectureResult is! GgufMetadata) return null;
    final architecture = architectureResult.values[ggufArchitectureKey];
    if (architecture == null || architecture.isEmpty) return null;

    final metadataResult = await readGgufMetadataFile(
      modelPath,
      keys: ggufMemoryMetadataKeys(architecture),
    );
    if (metadataResult is! GgufMetadata) return null;

    final modelBytes = await File(modelPath).length();
    final mmprojBytes = mmprojPath == null
        ? 0
        : await File(mmprojPath).length();
    final draftBytes = draftPath == null ? 0 : await File(draftPath).length();
    return estimateModelMemory(
      architecture: architecture,
      metadata: metadataResult.numericValues,
      modelFileSizeBytes: modelBytes + mmprojBytes,
      draftFileSizeBytes: draftBytes,
    );
  } on Object {
    return null;
  }
}

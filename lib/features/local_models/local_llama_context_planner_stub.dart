/// Web implementation of the local-model memory estimate reader.
///
/// The web engine (wllama) manages its own storage and the browser exposes
/// no honest memory measurements, so estimation is skipped and models load
/// with their configured context size.
library;

import 'package:llama_cpp_flutter/orchestration.dart';

/// Always returns null: no estimation without a filesystem.
Future<ModelMemoryEstimate?> readLocalLlamaMemoryEstimate({
  required String modelPath,
  String? mmprojPath,
  String? draftPath,
}) async => null;

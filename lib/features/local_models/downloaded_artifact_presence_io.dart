/// Native implementation of the downloaded-artifact presence check.
library;

import 'dart:io';

/// Whether a non-empty file exists at [path].
///
/// A zero-length file is treated as absent: that is what a download
/// interrupted before its first chunk leaves behind, and warming from it
/// would hand the loader a truncated GGUF.
Future<bool> downloadedArtifactExists(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  return await file.length() > 0;
}

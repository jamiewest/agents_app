/// Web implementation of the downloaded-artifact presence check.
///
/// Rarely consulted: the warm-up's web probe asks the runtime's managed
/// OPFS storage by URL instead (`downloadedArtifactsInManagedStorage`),
/// because a URL-backed model on web lives in browser storage rather than
/// at a filesystem path. This path-based check exists only to satisfy the
/// shared native signature.
library;

/// Always returns false: no filesystem to look in.
Future<bool> downloadedArtifactExists(String path) async => false;

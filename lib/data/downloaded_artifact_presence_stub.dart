/// Web implementation of the downloaded-artifact presence check.
///
/// A URL-backed model on web lives in the browser's cache rather than at a
/// path, and the engine exposes no cheap "is it cached?" query — asking would
/// mean starting the fetch that this check exists to avoid. Reporting absence
/// leaves those models to load lazily on the first message, where the
/// progress banner explains the wait.
///
/// This does not disable warm-up on web outright: a model backed by a picked
/// file is already in origin-private storage, so it never reaches this check
/// and warms like its native counterpart.
library;

/// Always returns false: no filesystem to look in.
Future<bool> downloadedArtifactExists(String path) async => false;

/// "Is this already on disk?" check for downloaded local-model artifacts.
///
/// The startup warm-up uses it to decide whether making a local model
/// resident is free (the GGUF is already downloaded) or would silently pull
/// gigabytes over the network. Only the native implementation can answer;
/// see the stub for why the web build always says no.
library;

export 'downloaded_artifact_presence_stub.dart'
    if (dart.library.io) 'downloaded_artifact_presence_io.dart';

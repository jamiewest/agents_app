// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Persistent storage for picked local GGUF files so they survive an app
/// restart (or web page reload) without re-picking or re-downloading.
///
/// On web this is backed by the Origin Private File System (OPFS); on native
/// it copies picked files into the app's Application Support directory,
/// which — unlike the picked path itself — stays readable across restarts of
/// a sandboxed macOS/iOS build.
///
/// Files are keyed by the model config id and an artifact "kind" key
/// (`model` / `mmproj` / `draft`, i.e. `LlamaArtifactKind.name`).
library;

export 'local_model_store_stub.dart'
    if (dart.library.js_interop) 'local_model_store_web.dart'
    if (dart.library.io) 'local_model_store_io.dart';

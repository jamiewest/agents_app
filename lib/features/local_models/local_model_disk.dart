// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Disk accounting and byte-level deletion for local models, across every
/// store that holds their files.
///
/// A local model's bytes can live in two places, and the pair differs by
/// platform:
///
/// * files the user *picked*, copied into the app's own storage by
///   `local_model_store.dart`;
/// * files the runtime *downloaded* — `local_llama/<modelId>` directories on
///   native (the download service), the llama_cpp_flutter managed artifact
///   store on web.
///
/// This library is the one place that knows about both, so "how much disk
/// does this model use" and "free this model's bytes" cannot silently miss a
/// store. Deleting bytes leaves the model's configuration alone: a URL-backed
/// model downloads again the next time it runs, a picked-file model needs
/// its file picked again.
library;

export 'local_model_disk_stub.dart'
    if (dart.library.js_interop) 'local_model_disk_web.dart'
    if (dart.library.io) 'local_model_disk_io.dart';

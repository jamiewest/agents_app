// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Static facts about the machine the app is running on.
///
/// Complements the live memory readings the llama runtime's
/// `SystemMemoryMonitor` provides: that covers RAM, this covers the CPU —
/// which needs `dart:io`/`dart:ffi`, hence the platform split.
library;

export 'hardware_info_stub.dart' if (dart.library.io) 'hardware_info_io.dart';

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

/// Quits the app so the next manual launch starts from clean state.
///
/// Native platforms cannot relaunch themselves, so exiting is the closest
/// equivalent of the web page reload.
void restartApp() => exit(0);

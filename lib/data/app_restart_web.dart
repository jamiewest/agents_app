// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:web/web.dart' as web;

/// Reloads the page, restarting the app from clean state.
void restartApp() => web.window.location.reload();

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';

/// Web stub for the A2A host service: browsers cannot open server sockets,
/// so hosting is unavailable (pairing as a CLIENT still works via paste).
class A2AHostService {
  /// Creates the stub.
  A2AHostService(ServiceProvider services, {this.deviceName = 'web'});

  /// The name shown to pairing clients.
  final String deviceName;

  /// Always false on the web.
  bool get isRunning => false;

  /// Always null on the web.
  int? get port => null;

  /// Unsupported on the web.
  Future<void> start(List<SavedAgentConfig> agents, {int port = 41888}) =>
      throw UnsupportedError('Hosting agents is not available on the web.');

  /// No-op on the web.
  Future<void> stop() async {}

  /// Unsupported on the web.
  Future<PairingPayload> createPairingOffer() =>
      throw UnsupportedError('Hosting agents is not available on the web.');
}

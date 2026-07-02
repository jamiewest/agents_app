// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';

import '../views/configured_agents/configured_agents.dart';

/// The full agents/models/sources management surface, composed from the
/// package's [ConfiguredAgentsView].
class ManageAgentsScreen extends StatelessWidget {
  /// Creates a [ManageAgentsScreen].
  const ManageAgentsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final manager = services.getRequiredService<ConfiguredAgentsManager>();
    return Scaffold(
      appBar: AppBar(title: const Text('Manage agents')),
      body: Column(
        children: [
          const _WebSecurityNotice(),
          Expanded(child: ConfiguredAgentsView(manager: manager)),
        ],
      ),
    );
  }
}

class _WebSecurityNotice extends StatelessWidget {
  const _WebSecurityNotice();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.all(12),
    child: Text(
      'Keys are stored in secure storage. On the web this falls back to '
      'browser storage, which does not protect secrets — production apps '
      'should proxy provider requests through a backend.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

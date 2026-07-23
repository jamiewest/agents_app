// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
      appBar: AppBar(
        title: const Text('Manage agents'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.lock300, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Keys are stored in secure storage. On the web this falls '
              'back to browser storage — production apps should proxy '
              'provider requests through a backend.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

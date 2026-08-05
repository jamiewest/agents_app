// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../widgets/settings_page.dart';

/// Devices that have paired with this host, with the means to revoke them.
///
/// Revocation is the counterpart the pairing flow was missing: a bearer,
/// once issued, verified forever. Removing a device here deletes its bearer
/// hash, so its very next request is refused — the peer keeps its saved
/// teammate config and simply starts getting 401s.
class PairedDevicesScreen extends StatefulWidget {
  /// Creates a [PairedDevicesScreen].
  const PairedDevicesScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<PairedDevicesScreen> createState() => _PairedDevicesScreenState();
}

class _PairedDevicesScreenState extends State<PairedDevicesScreen> {
  late final AuthorizedClientsStore _store;
  List<PairedClient>? _clients;

  @override
  void initState() {
    super.initState();
    _store = AuthorizedClientsStore(
      widget.services.getRequiredService<KeyValueStore>(),
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    final clients = await _store.list();
    if (mounted) setState(() => _clients = clients);
  }

  Future<void> _revoke(PairedClient client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${client.clientName}?'),
        content: const Text(
          'The device loses access to your shared agents immediately. '
          'To reconnect, it has to pair again with a new code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.remove(client.bearerHash);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clients = _clients;
    return SettingsPage(
      title: 'Paired devices',
      children: [
        if (clients == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (clients.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No devices are paired. Share an agent and show its pairing '
              'code to let another device connect.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final client in clients)
            ListTile(
              leading: const Icon(LucideIcons.monitorSmartphone300),
              title: Text(client.clientName),
              subtitle: Text(switch (client.pairedAt) {
                final pairedAt? =>
                  'Paired ${MaterialLocalizations.of(context).formatShortDate(pairedAt.toLocal())}',
                null => 'Paired date unknown',
              }),
              trailing: IconButton(
                icon: Icon(
                  LucideIcons.trash2300,
                  color: theme.colorScheme.error,
                ),
                tooltip: 'Remove',
                onPressed: () => unawaited(_revoke(client)),
              ),
            ),
      ],
    );
  }
}

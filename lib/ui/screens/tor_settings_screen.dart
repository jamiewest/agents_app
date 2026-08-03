// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:tor_flutter/tor_flutter.dart';

import '../../features/tor/tor_settings.dart';
import '../widgets/settings_page.dart';

/// The app-wide Tor switch.
///
/// Separate from sharing because the two are not the same decision: reaching
/// a peer's onion address needs Tor running, hosting one of your own is an
/// extra step taken per agent.
class TorSettingsScreen extends StatelessWidget {
  /// Creates a [TorSettingsScreen].
  const TorSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final settings = services.getService<TorSettings>();
    return SettingsPage(
      title: 'Tor',
      children: [
        if (settings == null)
          const _Unavailable()
        else
          ListenableBuilder(
            listenable: settings,
            builder: (context, _) => _Body(settings: settings),
          ),
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => const ListTile(
    title: Text('Tor is not available on this platform'),
    subtitle: Text(
      'Browsers cannot open the connections Tor needs, so this device can '
      'neither reach onion addresses nor publish one.',
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.settings});

  final TorSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          value: settings.enabled,
          title: const Text('Enable Tor'),
          subtitle: Text(_subtitleFor(settings)),
          // Disabled rather than hidden when no gateway is set: the switch is
          // the thing people look for, and removing it would read as Tor being
          // unavailable rather than unconfigured.
          onChanged: settings.busy || !settings.canStart
              ? null
              : (value) => unawaited(settings.setEnabled(value)),
        ),
        if (settings.requiresGateway) _GatewayField(settings: settings),
        if (settings.status case final TorBootstrapping status
            when settings.enabled) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: status.progress),
        ],
        const SizedBox(height: 16),
        Text(
          'Turn this on to reach agents shared at a .onion address. The first '
          'connection takes a while — Tor builds a circuit before anything '
          'can go through it.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text(
          'Sharing your own agents over Tor is a separate switch on each '
          "agent's page, and needs this on first.",
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (settings.error case final error?) ...[
          const SizedBox(height: 16),
          Text(error, style: TextStyle(color: scheme.error)),
        ],
      ],
    );
  }

  static String _subtitleFor(TorSettings settings) => switch (settings.status) {
    TorBootstrapping(:final progress) when settings.enabled =>
      'Connecting… ${(progress * 100).round()}%',
    TorReady() when settings.enabled => 'Connected',
    TorFailed() when settings.enabled => 'Could not connect',
    _ when !settings.canStart => 'Add a gateway below to switch this on',
    _ => 'Reach agents shared at a .onion address from anywhere',
  };
}

/// Where the browser sends its Tor traffic.
///
/// Only shown on the web. A browser cannot open a connection to a Tor relay,
/// so it needs a gateway to forward bytes on its behalf — one that sees only
/// encrypted Tor cells, never the destination or the content.
class _GatewayField extends StatefulWidget {
  const _GatewayField({required this.settings});

  final TorSettings settings;

  @override
  State<_GatewayField> createState() => _GatewayFieldState();
}

class _GatewayFieldState extends State<_GatewayField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.gateway,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            // Saved on submit rather than on every keystroke: a half-typed
            // address is never a valid one, and persisting each character
            // would make the stored value briefly nonsense.
            onSubmitted: (value) =>
                unawaited(widget.settings.setGateway(value)),
            enabled: !widget.settings.enabled,
            decoration: const InputDecoration(
              labelText: 'Gateway address',
              hintText: '203.0.113.5:12298:uEiAx…9Qw',
              helperText: 'Press enter to save. Takes effect on next connect.',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'A gateway forwards encrypted Tor traffic for browsers, which '
            'cannot reach relays directly. It never learns which address you '
            'are contacting.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

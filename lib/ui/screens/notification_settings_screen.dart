// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../dialogs/pushover_credentials.dart';
import '../widgets/settings_page.dart';

/// The Notifications sub-page: the Pushover credentials agents send through.
///
/// The credentials are app-wide; whether a given agent may use them is that
/// agent's own switch in its editor. Before this page the only ways in were
/// a hint inside the agent editor — not where anyone holding a Pushover
/// token thinks to look.
class NotificationSettingsScreen extends StatelessWidget {
  /// Creates a [NotificationSettingsScreen].
  const NotificationSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final settings = services.getService<PushoverSettings>();
    return SettingsPage(
      title: 'Notifications',
      children: [
        const SettingsGroupCaption(
          'Agents can send you push notifications through Pushover — a '
          'reminder going off, a long task finishing. The recipient is '
          'fixed by these credentials; an agent can never choose who is '
          'notified.',
        ),
        const SettingsGroupLabel('Pushover'),
        if (settings == null)
          const ListTile(
            title: Text('Notifications are not available on this platform'),
          )
        else
          ListenableBuilder(
            listenable: settings,
            builder: (context, _) => ListTile(
              leading: const Icon(LucideIcons.bellRing300),
              title: const Text('Pushover credentials'),
              subtitle: Text(
                settings.isConfigured
                    ? 'Configured — agents with notifications switched on '
                          'can reach you'
                    : 'Add an application token and user key from '
                          'pushover.net',
              ),
              trailing: const Icon(LucideIcons.chevronRight300),
              onTap: () =>
                  unawaited(showPushoverCredentialsDialog(context, settings)),
            ),
          ),
        const SettingsGroupCaption(
          'Each agent has its own notifications switch in its editor, so '
          'only the agents you choose can send anything.',
        ),
      ],
    );
  }
}

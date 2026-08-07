// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/chat_settings.dart';
import '../widgets/settings_page.dart';
import '../widgets/settings_shell.dart';

/// The General sub-page: app-wide odds and ends that belong to no other
/// section — re-running first-run setup, and the danger zone.
///
/// The reset row lives here rather than loose on the Settings page so the
/// destructive action sits behind one deliberate step, under a heading that
/// says what it is — the danger-zone pattern desktop settings surfaces use.
class GeneralSettingsScreen extends StatelessWidget {
  /// Creates a [GeneralSettingsScreen].
  const GeneralSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsPage(
      title: 'General',
      children: [
        const SettingsGroupLabel('Getting started'),
        ListTile(
          leading: const Icon(LucideIcons.rocket300),
          title: const Text('Start onboarding'),
          subtitle: const Text(
            'Reopen the first-run setup. Nothing you have is changed.',
          ),
          trailing: const Icon(LucideIcons.chevronRight300),
          onTap: () => context.go('/settings/general/onboarding'),
        ),
        const SettingsGroupLabel('Chat'),
        ListenableBuilder(
          listenable: services.getRequiredService<ChatSettings>(),
          builder: (context, _) {
            final chat = services.getRequiredService<ChatSettings>();
            return SwitchListTile(
              secondary: const Icon(LucideIcons.letterText300),
              title: const Text('Auto-title conversations'),
              subtitle: const Text(
                'While the app sits idle, the loaded local model writes '
                'short titles for untitled conversations. Off, titles stay '
                'as the first message.',
              ),
              value: chat.autoTitleEnabled,
              onChanged: (enabled) =>
                  unawaited(chat.setAutoTitleEnabled(enabled)),
            );
          },
        ),
        const Divider(height: 32),
        const SettingsGroupLabel('Danger zone'),
        ListTile(
          leading: Icon(LucideIcons.rotateCcw300, color: scheme.error),
          title: Text('Reset app data', style: TextStyle(color: scheme.error)),
          subtitle: const Text(
            'Erase all agents, API keys, conversations, and downloaded '
            'models, then start fresh',
          ),
          onTap: () => unawaited(confirmAndResetAppData(context, services)),
        ),
      ],
    );
  }
}

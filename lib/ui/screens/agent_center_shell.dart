// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../navigation/app_shell.dart';
import 'agent_center_nav.dart';

/// The persistent chrome around the Agent Center's four pages.
///
/// Built once by the Agent Center's [StatefulShellRoute]; only the content
/// area — the branch navigator [shell] — swaps as tabs change or a list
/// pushes to an item. The secondary nav never rebuilds, so switching tabs no
/// longer animates the whole menu in.
class AgentCenterShell extends StatelessWidget {
  /// Creates an [AgentCenterShell].
  const AgentCenterShell({required this.services, required this.shell, super.key});

  /// The application service provider.
  final ServiceProvider services;

  /// The branch navigator for the active tab, and the state that drives it.
  final StatefulNavigationShell shell;

  /// Switches to [index], resetting that branch to its root when the active
  /// tab is re-tapped — the same idiom the app's outer rail uses.
  void _goBranch(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sideNav = constraints.maxWidth >= 600;
      final current = AgentCenterTab.values[shell.currentIndex];
      final nav = AgentCenterNav(
        current: current,
        vertical: sideNav,
        onSelected: (tab) => _goBranch(tab.index),
      );

      if (sideNav) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 184,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 20, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 12),
                          child: Text(
                            'Agent Center',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        nav,
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: shell),
              ],
            ),
          ),
        );
      }

      // Compact: the tabs sit in a slim top bar and stay put while a detail
      // or editor pushes into the content area below them.
      final openDrawer = AppShellScope.openDrawerOf(context);
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
                child: Row(
                  children: [
                    if (openDrawer != null)
                      IconButton(
                        tooltip: 'Menu',
                        icon: const Icon(LucideIcons.menu300),
                        onPressed: openDrawer,
                      ),
                    Text(
                      'Agent Center',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: nav,
              ),
              const Divider(height: 1),
              Expanded(child: shell),
            ],
          ),
        ),
      );
    },
  );
}

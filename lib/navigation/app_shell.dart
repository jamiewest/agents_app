// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The responsive top-level scaffold around the Chats/Tasks/Settings shell.
///
/// Built on the adaptive-layout primitives: a bottom [NavigationBar] on
/// compact widths, a [NavigationRail] from medium, and an extended rail
/// with a leading FAB-style affordance from large. Branch state is
/// preserved by the underlying [StatefulNavigationShell]; slot changes
/// animate as the window resizes.
class AppShell extends StatelessWidget {
  /// Creates an [AppShell].
  const AppShell({required this.shell, super.key});

  /// The router's stateful branch container.
  final StatefulNavigationShell shell;

  static const _destinations = [
    (icon: Icons.chat_bubble_outline, selected: Icons.chat_bubble, label: 'Chats'),
    (icon: Icons.task_alt_outlined, selected: Icons.task_alt, label: 'Tasks'),
    (
      icon: Icons.settings_outlined,
      selected: Icons.settings,
      label: 'Settings',
    ),
  ];

  void _goBranch(int index) => shell.goBranch(
    index,
    // Re-tapping the active destination pops that branch to its root.
    initialLocation: index == shell.currentIndex,
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AdaptiveLayout(
      transitionDuration: const Duration(milliseconds: 250),
      primaryNavigation: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.medium: SlotLayout.from(
            key: const Key('primary-rail'),
            builder: (context) => _buildRail(context, extended: false),
          ),
          Breakpoints.mediumLargeAndUp: SlotLayout.from(
            key: const Key('primary-rail-extended'),
            builder: (context) => _buildRail(context, extended: true),
          ),
        },
      ),
      bottomNavigation: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.small: SlotLayout.from(
            key: const Key('bottom-navigation'),
            builder: (context) => NavigationBar(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: _goBranch,
              destinations: [
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selected),
                    label: destination.label,
                  ),
              ],
            ),
          ),
        },
      ),
      body: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.standard: SlotLayout.from(
            key: const Key('shell-body'),
            builder: (context) => shell,
          ),
        },
      ),
    ),
  );

  Widget _buildRail(BuildContext context, {required bool extended}) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: NavigationRail(
        extended: extended,
        minExtendedWidth: 172,
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _goBranch,
        labelType: extended
            ? NavigationRailLabelType.none
            : NavigationRailLabelType.all,
        leading: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: extended
              ? FloatingActionButton.extended(
                  elevation: 0,
                  backgroundColor: scheme.tertiaryContainer,
                  foregroundColor: scheme.onTertiaryContainer,
                  onPressed: () => context.go('/chats'),
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('agents'),
                )
              : FloatingActionButton.small(
                  elevation: 0,
                  backgroundColor: scheme.tertiaryContainer,
                  foregroundColor: scheme.onTertiaryContainer,
                  onPressed: () => context.go('/chats'),
                  child: const Icon(Icons.forum_outlined),
                ),
        ),
        destinations: [
          for (final destination in _destinations)
            NavigationRailDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selected),
              label: Text(destination.label),
            ),
        ],
      ),
    );
  }
}

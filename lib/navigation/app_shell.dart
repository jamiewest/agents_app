// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The responsive top-level scaffold around the Chats/Tasks/Settings shell.
///
/// Built on the adaptive-layout primitives: a bottom [NavigationBar] on
/// compact widths and a compact [NavigationRail] from medium. Branch state
/// is preserved by the underlying [StatefulNavigationShell]; slot changes
/// animate as the window resizes.
class AppShell extends StatelessWidget {
  /// Creates an [AppShell].
  const AppShell({required this.shell, super.key});

  /// The router's stateful branch container.
  final StatefulNavigationShell shell;

  static const _destinations = [
    (
      icon: Icons.chat_bubble_outline,
      selected: Icons.chat_bubble,
      label: 'Chats',
    ),
    (icon: Icons.alarm_rounded, selected: Icons.alarm_rounded, label: 'Tasks'),
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
      // The default entrance/exit animations keep the ticker busy (they
      // starve pumpAndSettle and add churn on every resize); breakpoint
      // swaps are instant instead.
      internalAnimations: false,
      primaryNavigation: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.mediumAndUp: SlotLayout.from(
            key: const Key('primary-rail'),
            builder: _buildRail,
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

  Widget _buildRail(BuildContext context) =>
      // The adaptive layout hands navigation slots LOOSE full-screen
      // constraints and trusts them to size themselves; a bare
      // NavigationRail expands under loose width and starves the body, so
      // pin the slot's width here.
      SizedBox(
        width: 78,
        child: SafeArea(
          child: NavigationRail(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: _goBranch,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final destination in _destinations)
                NavigationRailDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selected),
                  label: Text(
                    destination.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      );
}

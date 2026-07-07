// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/screens/chats_home.dart';

/// Exposes the compact-width shell drawer to descendant pages, so their
/// headers can show a hamburger button that opens it.
class AppShellScope extends InheritedWidget {
  /// Creates an [AppShellScope].
  const AppShellScope({
    required this.openDrawer,
    required super.child,
    super.key,
  });

  /// Opens the shell drawer, or null when the shell has no drawer (wide
  /// layouts navigate through the rail instead).
  final VoidCallback? openDrawer;

  /// The nearest shell's drawer opener, or null when no drawer is showing.
  static VoidCallback? openDrawerOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>()?.openDrawer;

  @override
  bool updateShouldNotify(AppShellScope oldWidget) =>
      openDrawer != oldWidget.openDrawer;
}

/// The responsive top-level scaffold around the Chats/Tasks/Settings shell.
///
/// Built on the adaptive-layout primitives: a navigation [Drawer] (opened
/// from a hamburger button in each page header) on compact widths and a
/// compact [NavigationRail] from medium. Branch state is preserved by the
/// underlying [StatefulNavigationShell]; slot changes animate as the window
/// resizes.
class AppShell extends StatefulWidget {
  /// Creates an [AppShell].
  const AppShell({required this.services, required this.shell, super.key});

  /// The application service provider, used by the drawer's chats list.
  final ServiceProvider services;

  /// The router's stateful branch container.
  final StatefulNavigationShell shell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

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

  void _goBranch(int index) => widget.shell.goBranch(
    index,
    // Re-tapping the active destination pops that branch to its root.
    initialLocation: index == widget.shell.currentIndex,
  );

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  @override
  Widget build(BuildContext context) {
    final compact = Breakpoints.small.isActive(context);
    return AppShellScope(
      openDrawer: compact ? _openDrawer : null,
      child: Scaffold(
        key: _scaffoldKey,
        drawer: compact
            ? _AppDrawer(
                services: widget.services,
                selectedIndex: widget.shell.currentIndex,
                onDestinationSelected: _goBranch,
              )
            : null,
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
          body: SlotLayout(
            config: <Breakpoint, SlotLayoutConfig>{
              Breakpoints.standard: SlotLayout.from(
                key: const Key('shell-body'),
                builder: (context) => widget.shell,
              ),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRail(BuildContext context) =>
      // The adaptive layout hands navigation slots LOOSE full-screen
      // constraints and trusts them to size themselves; a bare
      // NavigationRail expands under loose width and starves the body, so
      // pin the slot's width here.
      SizedBox(
        width: 78,
        child: SafeArea(
          child: NavigationRail(
            selectedIndex: widget.shell.currentIndex,
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

/// The compact-width navigation drawer: the top-level destinations near the
/// top, then the persistent conversations/channels list below them.
class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.services,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final ServiceProvider services;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) => Drawer(
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          for (final (index, destination)
              in _AppShellState._destinations.indexed)
            ListTile(
              leading: Icon(
                index == selectedIndex
                    ? destination.selected
                    : destination.icon,
              ),
              title: Text(destination.label),
              selected: index == selectedIndex,
              onTap: () {
                Scaffold.of(context).closeDrawer();
                onDestinationSelected(index);
              },
            ),
          const SizedBox(height: 8),
          const Divider(),
          Expanded(
            child: ChatsListView(
              services: services,
              presentation: ChatsListPresentation.drawer,
            ),
          ),
        ],
      ),
    ),
  );
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../ui/app_theme.dart';
import '../ui/screens/chats_home.dart';
import '../ui/widgets/side_panel_host.dart';

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
    (icon: Symbols.chat_bubble, label: 'Chats'),
    (icon: Symbols.alarm_rounded, label: 'Tasks'),
    (icon: Symbols.settings, label: 'Settings'),
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
        // The side panel overlays the whole adaptive layout — rail and
        // body alike — so pages can slide utility content over the app
        // without reflowing it.
        body: SidePanelHost(
          child: AdaptiveLayout(
            transitionDuration: const Duration(milliseconds: 250),
            // The default entrance/exit animations keep the ticker busy
            // (they starve pumpAndSettle and add churn on every resize);
            // breakpoint swaps are instant instead.
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
                  // Material Symbols renders the selected state through the
                  // fill variation axis rather than a separate filled icon.
                  selectedIcon: Icon(destination.icon, fill: 1),
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

/// The compact-width navigation drawer: the conversations/channels list
/// fills the top, and the top-level destinations sit anchored to the bottom
/// where a thumb can reach them.
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
          Expanded(
            child: ChatsListView(
              services: services,
              presentation: ChatsListPresentation.drawer,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, destination)
                    in _AppShellState._destinations.indexed)
                  _DrawerDestination(
                    icon: destination.icon,
                    label: destination.label,
                    selected: index == selectedIndex,
                    onTap: () {
                      Scaffold.of(context).closeDrawer();
                      onDestinationSelected(index);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// A stadium-shaped destination tile for the drawer's bottom menu, matching
/// the conversation tiles above it.
class _DrawerDestination extends StatelessWidget {
  const _DrawerDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      child: Material(
        shape: const StadiumBorder(),
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  fill: selected ? 1 : 0,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

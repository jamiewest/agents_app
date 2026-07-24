// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../navigation/app_shell.dart';

/// One tab of a settings section shell.
typedef SectionDestination = ({String label, IconData icon});

/// The persistent chrome around a multi-page settings section, built once by
/// the section's [StatefulShellRoute].
///
/// The same design the Agent Center uses: a titled secondary nav that stays
/// mounted while only the content branch ([shell]) swaps, so changing tabs
/// never re-animates the menu. On wide layouts the nav is a labelled rail
/// beside the content; on compact it is a scrollable segmented control above
/// it, with a hamburger to reach the app drawer.
class SettingsSectionShell extends StatelessWidget {
  /// Creates a [SettingsSectionShell].
  const SettingsSectionShell({
    required this.title,
    required this.destinations,
    required this.shell,
    super.key,
  });

  /// The section heading, e.g. "Logs & diagnostics".
  final String title;

  /// The tabs, in branch order so [shell]'s index maps straight to one.
  final List<SectionDestination> destinations;

  /// The branch navigator for the active tab.
  final StatefulNavigationShell shell;

  void _go(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sideNav = constraints.maxWidth >= 600;
      final nav = SectionNav(
        destinations: destinations,
        selectedIndex: shell.currentIndex,
        vertical: sideNav,
        onSelected: _go,
      );

      if (sideNav) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 200,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 20, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 12),
                          child: Text(
                            title,
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
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
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

/// A settings section's persistent secondary navigation.
///
/// Horizontal (a [SegmentedButton]) when stacked above content on narrow
/// layouts, vertical (a button column) when it sits beside content.
class SectionNav extends StatelessWidget {
  /// Creates a [SectionNav].
  const SectionNav({
    required this.destinations,
    required this.selectedIndex,
    required this.vertical,
    required this.onSelected,
    super.key,
  });

  /// The tabs.
  final List<SectionDestination> destinations;

  /// The active tab index.
  final int selectedIndex;

  /// Whether to lay the tabs out in a column.
  final bool vertical;

  /// Invoked with the chosen tab index.
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (!vertical) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<int>(
          segments: [
            for (final (index, destination) in destinations.indexed)
              ButtonSegment(
                value: index,
                label: Text(destination.label),
                icon: Icon(destination.icon, size: 18),
              ),
          ],
          selected: {selectedIndex},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onSelected(selection.first),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, destination) in destinations.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _NavButton(
              destination: destination,
              selected: index == selectedIndex,
              onPressed: () => onSelected(index),
            ),
          ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final SectionDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(destination.icon, size: 18),
        label: Text(destination.label),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          minimumSize: const Size(140, 44),
          backgroundColor: selected ? scheme.secondaryContainer : null,
          foregroundColor: selected
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

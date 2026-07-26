// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../navigation/app_shell.dart';
import '../app_theme.dart';
import 'draggable_separator.dart';

/// One tab of a settings section shell.
typedef SectionDestination = ({String label, IconData icon});

/// The back control a settings section shows in its header.
///
/// Sections are sibling routes of `/settings` rather than pages pushed over
/// it, so there is nothing to pop — this navigates to [location]. It wears
/// the app's [AppBackIcon] so it reads as back navigation everywhere else
/// does, and names its destination in the tooltip since it carries no label.
class SettingsBackButton extends StatelessWidget {
  /// Creates a [SettingsBackButton].
  const SettingsBackButton({this.location = '/settings', super.key});

  /// Where the button navigates — the page the section was opened from.
  final String location;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Back to settings',
    icon: const AppBackIcon(),
    onPressed: () => context.go(location),
  );
}

/// The persistent chrome around a multi-page settings section, built once by
/// the section's [StatefulShellRoute].
///
/// The same design the Agent Center uses: a titled secondary nav that stays
/// mounted while only the content branch ([shell]) swaps, so changing tabs
/// never re-animates the menu. The nav is not rebuilt by navigation; it
/// rebuilds only while its panel is being resized.
///
/// On wide layouts the nav is a resizable side panel that mirrors the chats
/// sidebar — same surface, header geometry, tile shape, and drag handle — so
/// the two read as the same piece of furniture: one a menu, the other a list.
/// On compact layouts it is a scrollable segmented control above the content,
/// with a hamburger to reach the app drawer.
///
/// A section is entered by branch switch rather than a push, so there is no
/// route to pop back to; the header's back button navigates to
/// [backLocation] explicitly.
class SettingsSectionShell extends StatefulWidget {
  /// Creates a [SettingsSectionShell].
  const SettingsSectionShell({
    required this.title,
    required this.icon,
    required this.destinations,
    required this.shell,
    required this.backLocation,
    super.key,
  });

  /// The section heading, e.g. "Logs & diagnostics". Rendered upper-case in
  /// the panel's brand treatment.
  final String title;

  /// The section's glyph, leading the heading. Use the same icon as the
  /// Settings entry that leads here, so the section keeps one identity.
  final IconData icon;

  /// The tabs, in branch order so [shell]'s index maps straight to one.
  final List<SectionDestination> destinations;

  /// The branch navigator for the active tab.
  final StatefulNavigationShell shell;

  /// Where the back button goes — the page this section was opened from.
  final String backLocation;

  /// The side panel's starting width, matching the chats sidebar.
  static const double defaultNavWidth = 300;

  /// The narrowest the side panel can be dragged, matching the chats
  /// sidebar; also the floor the panel falls back to when the window is too
  /// narrow to honour the user's width.
  static const double minNavWidth = 248;

  /// The widest the side panel can be dragged, matching the chats sidebar.
  static const double maxNavWidth = 480;

  /// The width the content area keeps before the side panel gives ground.
  static const double _minContentWidth = 360;

  @override
  State<SettingsSectionShell> createState() => _SettingsSectionShellState();
}

class _SettingsSectionShellState extends State<SettingsSectionShell> {
  double _navWidth = SettingsSectionShell.defaultNavWidth;

  void _go(int index) => widget.shell.goBranch(
    index,
    initialLocation: index == widget.shell.currentIndex,
  );

  /// The width to actually render at: the user's width, given back to the
  /// content area when the window cannot afford it. The stored width is left
  /// alone so widening the window restores it.
  double _renderedNavWidth(double available) => math.min(
    _navWidth,
    math.max(
      SettingsSectionShell.minNavWidth,
      available - SettingsSectionShell._minContentWidth,
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sideNav = constraints.maxWidth >= 600;
      final nav = SectionNav(
        destinations: widget.destinations,
        selectedIndex: widget.shell.currentIndex,
        vertical: sideNav,
        onSelected: _go,
      );

      if (sideNav) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                SizedBox(
                  width: _renderedNavWidth(constraints.maxWidth),
                  // A Material, not a plain ColoredBox: the nav tiles ink,
                  // and the panel sits outside the Scaffold's own surface.
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SectionHeader(
                          title: widget.title,
                          icon: widget.icon,
                          backLocation: widget.backLocation,
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: nav,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                DraggableSeparator(
                  onDragUpdate: (deltaX) => setState(() {
                    _navWidth = (_navWidth + deltaX).clamp(
                      SettingsSectionShell.minNavWidth,
                      SettingsSectionShell.maxNavWidth,
                    );
                  }),
                ),
                Expanded(child: widget.shell),
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
                    SettingsBackButton(location: widget.backLocation),
                    if (openDrawer != null)
                      IconButton(
                        tooltip: 'Menu',
                        icon: const Icon(LucideIcons.menu300),
                        onPressed: openDrawer,
                      ),
                    Flexible(
                      child: _SectionTitle(
                        title: widget.title,
                        icon: widget.icon,
                        showIcon: openDrawer == null,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: nav,
              ),
              const Divider(height: 1),
              Expanded(child: widget.shell),
            ],
          ),
        ),
      );
    },
  );
}

/// The side panel's header, laid out on the chats sidebar's geometry so a
/// section's nav and the conversations list start at the same place.
///
/// The chats header ends in icon buttons; this one ends in the back control,
/// which keeps the 48pt hit target that sets the header's height.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.backLocation,
  });

  final String title;
  final IconData icon;
  final String backLocation;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.sm,
    ),
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(child: _SectionTitle(title: title, icon: icon)),
          SettingsBackButton(location: backLocation),
        ],
      ),
    ),
  );
}

/// The section heading in the chats sidebar's brand treatment.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.icon,
    this.showIcon = true,
  });

  final String title;
  final IconData icon;

  /// Whether to lead with the section glyph. Suppressed on compact layouts
  /// that already open with the drawer button.
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        if (showIcon) ...[
          Icon(icon, color: scheme.primary, size: 24),
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

/// A settings section's persistent secondary navigation.
///
/// Horizontal (a [SegmentedButton]) when stacked above content on narrow
/// layouts, vertical (a column of sidebar tiles) when it sits beside content.
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
          _NavTile(
            destination: destination,
            selected: index == selectedIndex,
            onPressed: () => onSelected(index),
          ),
      ],
    );
  }
}

/// One entry in the vertical nav, shaped like a conversation tile in the
/// chats sidebar: same stadium, same insets, same selected fill, so a menu
/// and a list of conversations sit at the same rhythm.
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.destination,
    required this.selected,
    required this.onPressed,
  });

  final SectionDestination destination;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Semantics(
      selected: selected,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 1,
        ),
        child: Material(
          shape: const StadiumBorder(),
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 6,
              ),
              child: Row(
                children: [
                  // Sized to the conversation tiles' 28pt avatar so both
                  // lists share one text column.
                  SizedBox.square(
                    dimension: 28,
                    child: Icon(destination.icon, size: 18, color: foreground),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

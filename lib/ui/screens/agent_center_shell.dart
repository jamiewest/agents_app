// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../navigation/app_shell.dart';
import '../app_theme.dart';
import '../widgets/draggable_separator.dart';
import 'agent_center_nav.dart';

/// The persistent chrome around the Agent Center's four pages.
///
/// Built once by the Agent Center's [StatefulShellRoute]; only the content
/// area — the branch navigator [shell] — swaps as tabs change or a list
/// pushes to an item. The secondary nav is not rebuilt by navigation, so
/// switching tabs no longer animates the whole menu in; it rebuilds only
/// while its panel is being resized.
///
/// On wide layouts the nav is a resizable side panel that mirrors the chats
/// sidebar — same surface, header geometry, tile shape, and drag handle — so
/// the two read as the same piece of furniture: one a menu, the other a list.
class AgentCenterShell extends StatefulWidget {
  /// Creates an [AgentCenterShell].
  const AgentCenterShell({
    required this.services,
    required this.shell,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The branch navigator for the active tab, and the state that drives it.
  final StatefulNavigationShell shell;

  /// The width the content area keeps before the side panel gives ground.
  static const double _minContentWidth = 360;

  @override
  State<AgentCenterShell> createState() => _AgentCenterShellState();
}

class _AgentCenterShellState extends State<AgentCenterShell> {
  double _navWidth = AppSidePanel.defaultWidth;

  /// Switches to [index], resetting that branch to its root when the active
  /// tab is re-tapped — the same idiom the app's outer rail uses.
  void _goBranch(int index) => widget.shell.goBranch(
    index,
    initialLocation: index == widget.shell.currentIndex,
  );

  /// The width to actually render at: the user's width, given back to the
  /// content area when the window cannot afford it. The stored width is left
  /// alone so widening the window restores it.
  double _renderedNavWidth(double available) => math.min(
    _navWidth,
    math.max(
      AppSidePanel.minWidth,
      available - AgentCenterShell._minContentWidth,
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sideNav = constraints.maxWidth >= 600;
      final current = AgentCenterTab.values[widget.shell.currentIndex];
      final nav = AgentCenterNav(
        current: current,
        vertical: sideNav,
        onSelected: (tab) => _goBranch(tab.index),
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
                        const _AgentCenterHeader(),
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
                      AppSidePanel.minWidth,
                      AppSidePanel.maxWidth,
                    );
                  }),
                ),
                Expanded(child: widget.shell),
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
                    Flexible(
                      child: _AgentCenterTitle(showIcon: openDrawer == null),
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

/// The side panel's header, laid out on the chats sidebar's geometry so the
/// nav and the conversations list start at the same place.
class _AgentCenterHeader extends StatelessWidget {
  const _AgentCenterHeader();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.sm,
    ),
    // The chats header ends in icon buttons whose 48pt hit targets set its
    // height; nothing here needs one, so match that height explicitly.
    child: SizedBox(height: 48, child: Center(child: _AgentCenterTitle())),
  );
}

/// "AGENT CENTER" in the chats sidebar's brand treatment.
class _AgentCenterTitle extends StatelessWidget {
  const _AgentCenterTitle({this.showIcon = true});

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
          Icon(LucideIcons.blocks300, color: scheme.primary, size: 24),
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(
          child: Text(
            'AGENT CENTER',
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

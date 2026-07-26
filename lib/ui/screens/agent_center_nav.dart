// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';

/// The top-level pages of the Agent Center, in nav order.
///
/// Overview leads the switcher but is not the landing page: people open the
/// center to add or fix an agent, so a deep link to `/settings/agents` still
/// arrives on Agents. Overview is one tab across.
enum AgentCenterTab {
  /// The operational dashboard.
  overview('Overview', LucideIcons.chartLine300, '/settings/agents/overview'),

  /// Saved agents — the landing page.
  agents('Agents', LucideIcons.bot300, '/settings/agents'),

  /// Configured models.
  models('Models', LucideIcons.boxes300, '/settings/agents/models'),

  /// Model sources.
  sources('Sources', LucideIcons.plug300, '/settings/agents/sources');

  const AgentCenterTab(this.label, this.icon, this.path);

  /// The nav label.
  final String label;

  /// The nav icon.
  final IconData icon;

  /// The route this tab navigates to.
  final String path;
}

/// The Agent Center's persistent secondary navigation.
///
/// Horizontal (a [SegmentedButton]) when stacked above content on narrow
/// layouts, vertical (a button column) when it sits beside content. Emits a
/// tab rather than navigating itself, so a host with unsaved edits can guard
/// the switch before it happens.
class AgentCenterNav extends StatelessWidget {
  /// Creates an [AgentCenterNav].
  const AgentCenterNav({
    required this.current,
    required this.vertical,
    required this.onSelected,
    super.key,
  });

  /// The tab currently shown.
  final AgentCenterTab current;

  /// Whether to lay the tabs out in a column.
  final bool vertical;

  /// Invoked with the chosen tab.
  final ValueChanged<AgentCenterTab> onSelected;

  @override
  Widget build(BuildContext context) {
    if (!vertical) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<AgentCenterTab>(
          segments: [
            for (final tab in AgentCenterTab.values)
              ButtonSegment(
                value: tab,
                label: Text(tab.label),
                icon: Icon(tab.icon, size: 18),
              ),
          ],
          selected: {current},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onSelected(selection.first),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final tab in AgentCenterTab.values)
          _NavTile(
            tab: tab,
            selected: tab == current,
            onPressed: () => onSelected(tab),
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
    required this.tab,
    required this.selected,
    required this.onPressed,
  });

  final AgentCenterTab tab;
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
                    child: Icon(tab.icon, size: 18, color: foreground),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      tab.label,
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

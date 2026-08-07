// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../widgets/settings_section_shell.dart';

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

/// The Agent Center's tabs as section-shell destinations, in branch order so
/// the shell's index maps straight to an [AgentCenterTab].
final List<SectionDestination> agentCenterDestinations = [
  for (final tab in AgentCenterTab.values) (label: tab.label, icon: tab.icon),
];

/// The live Agent Center branch navigator, published while its shell is
/// mounted.
///
/// The settings sidebar renders the center's tabs but sits outside its
/// route subtree, so it cannot reach the [StatefulNavigationShell] the way
/// the compact tab strip can. Switching tabs must go through
/// `shell.goBranch` — a plain `go` to a tab's path resets that branch's
/// stack, forgetting a pushed detail or editor. Null whenever the center is
/// not on screen; then a `go` is right, since there is no live stack to
/// lose.
final ValueNotifier<StatefulNavigationShell?> agentCenterShellBinding =
    ValueNotifier(null);

/// Navigates to [tab] the way its live shell would, or by path when the
/// Agent Center is not currently mounted.
void openAgentCenterTab(BuildContext context, AgentCenterTab tab) {
  final shell = agentCenterShellBinding.value;
  if (shell == null) {
    context.go(tab.path);
    return;
  }
  final index = AgentCenterTab.values.indexOf(tab);
  shell.goBranch(index, initialLocation: index == shell.currentIndex);
}

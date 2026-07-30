// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';
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

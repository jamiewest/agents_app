// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/settings_section_shell.dart';
import 'agent_center_nav.dart';

/// The persistent chrome around the Agent Center's four pages.
///
/// Nothing of its own beyond the tab list: the Agent Center is one of
/// Settings' sections, so it wears the shared [SettingsSectionShell] and
/// looks exactly like Logs & diagnostics and like the Settings page both were
/// opened from. Built once by the Agent Center's [StatefulShellRoute]; only
/// the content area — the branch navigator [shell] — swaps as tabs change or
/// a list pushes to an item.
class AgentCenterShell extends StatelessWidget {
  /// Creates an [AgentCenterShell].
  const AgentCenterShell({required this.shell, super.key});

  /// The branch navigator for the active tab, and the state that drives it.
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => SettingsSectionShell(
    title: 'Agent Center',
    destinations: agentCenterDestinations,
    shell: shell,
    backLocation: '/settings',
  );
}

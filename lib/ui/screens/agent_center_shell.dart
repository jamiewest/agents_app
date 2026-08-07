// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/settings_page.dart';
import '../widgets/settings_section_shell.dart';
import 'agent_center_nav.dart';

/// The persistent chrome around the Agent Center's four pages.
///
/// On compact layouts the Agent Center is one of Settings' drill-in
/// sections, so it wears the shared [SettingsSectionShell] — the same
/// tabbed chrome as Logs & diagnostics. In the shell's two-pane layout its
/// tabs are merged into the settings sidebar as first-class rows, so this
/// contributes only a title bar naming the active tab; a second tab strip
/// beside the sidebar's rows would be the same control twice.
///
/// Built once by the Agent Center's [StatefulShellRoute]; only the content
/// area — the branch navigator [shell] — swaps as tabs change or a list
/// pushes to an item.
class AgentCenterShell extends StatefulWidget {
  /// Creates an [AgentCenterShell].
  const AgentCenterShell({required this.shell, super.key});

  /// The branch navigator for the active tab, and the state that drives it.
  final StatefulNavigationShell shell;

  @override
  State<AgentCenterShell> createState() => _AgentCenterShellState();
}

class _AgentCenterShellState extends State<AgentCenterShell> {
  // Publishing happens in lifecycle hooks, not build: assigning during
  // build would notify any listener mid-frame.
  @override
  void initState() {
    super.initState();
    agentCenterShellBinding.value = widget.shell;
  }

  @override
  void didUpdateWidget(AgentCenterShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    agentCenterShellBinding.value = widget.shell;
  }

  @override
  void dispose() {
    // Only un-publish our own shell: a replacement page's initState may
    // have published before this dispose runs.
    if (agentCenterShellBinding.value == widget.shell) {
      agentCenterShellBinding.value = null;
    }
    super.dispose();
  }

  StatefulNavigationShell get shell => widget.shell;

  @override
  Widget build(BuildContext context) {
    if (!SettingsScope.twoPaneOf(context)) {
      return SettingsSectionShell(
        title: 'Agent Center',
        destinations: agentCenterDestinations,
        shell: shell,
        backLocation: '/settings',
      );
    }
    return Scaffold(
      appBar: AppBar(
        // The sidebar is the navigation; there is nothing to go back to.
        automaticallyImplyLeading: false,
        title: Text(AgentCenterTab.values[shell.currentIndex].label),
        // Matches [SettingsSectionShell]: the header shares the body's
        // surface and takes no elevation tint when content scrolls under it.
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      body: shell,
    );
  }
}

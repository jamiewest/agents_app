// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app_theme.dart';

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
/// A section is a Settings sub-page that happens to have more than one page
/// in it, so it wears the same chrome as any other: the single-row header the
/// Settings destination uses, with a back control where the drawer button
/// sits there. Its pages are a segmented control directly under that header —
/// at every width, so the section looks the same on a phone and on a desktop
/// and, more to the point, looks like the Settings page it was opened from.
///
/// The nav stays mounted while only the content branch ([shell]) swaps, so
/// changing tabs never re-animates the menu.
///
/// A section is entered by branch switch rather than a push, so there is no
/// route to pop back to; the header's back button navigates to
/// [backLocation] explicitly.
class SettingsSectionShell extends StatelessWidget {
  /// Creates a [SettingsSectionShell].
  const SettingsSectionShell({
    required this.title,
    required this.destinations,
    required this.shell,
    required this.backLocation,
    super.key,
  });

  /// The section heading, e.g. "Logs & diagnostics".
  final String title;

  /// The tabs, in branch order so [shell]'s index maps straight to one.
  final List<SectionDestination> destinations;

  /// The branch navigator for the active tab.
  final StatefulNavigationShell shell;

  /// Where the back button goes — the page this section was opened from.
  final String backLocation;

  void _go(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: SettingsBackButton(location: backLocation),
      title: Text(title),
      // Matches [AppSliverHeader]: the header shares the body's surface and
      // takes no elevation tint when content scrolls under it.
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      scrolledUnderElevation: 0,
      elevation: 0,
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: SectionNav(
            destinations: destinations,
            selectedIndex: shell.currentIndex,
            onSelected: _go,
          ),
        ),
        const Divider(height: 1),
        Expanded(child: shell),
      ],
    ),
  );
}

/// A settings section's persistent secondary navigation: one segmented
/// control listing the section's pages.
class SectionNav extends StatelessWidget {
  /// Creates a [SectionNav].
  const SectionNav({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  /// The tabs.
  final List<SectionDestination> destinations;

  /// The active tab index.
  final int selectedIndex;

  /// Invoked with the chosen tab index.
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
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

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import 'app_sliver_header.dart';
import 'page_body.dart';

/// The Settings layout mode, shared down to every page in the Settings
/// branch by the settings shell.
///
/// On wide layouts the shell keeps a persistent section sidebar beside the
/// page, so pages drop the navigation chrome the sidebar makes redundant —
/// most visibly the back-to-settings control, which would otherwise lead to
/// a placeholder pane sitting beside the very list the user can see.
class SettingsScope extends InheritedWidget {
  /// Creates a [SettingsScope].
  const SettingsScope({required this.twoPane, required super.child, super.key});

  /// Whether the settings shell is showing its persistent section sidebar
  /// beside the page.
  final bool twoPane;

  /// Whether the nearest settings shell is in its two-pane (wide) layout.
  ///
  /// False outside the Settings branch, so widgets shared with other
  /// surfaces keep their normal chrome there.
  static bool twoPaneOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()?.twoPane ??
      false;

  @override
  bool updateShouldNotify(SettingsScope oldWidget) =>
      twoPane != oldWidget.twoPane;
}

/// The chrome every Settings sub-page wears.
///
/// The same single-row header the Settings destination itself uses, with a
/// back control where the drawer button sits there, over content laid out on
/// the app's reading column. Sub-pages use this rather than their own
/// [Scaffold] and [AppBar] so a drill-down out of Settings never changes the
/// header's height, type, or colour. In the shell's two-pane layout the back
/// control is dropped: the sidebar beside the page is the navigation.
class SettingsPage extends StatelessWidget {
  /// Creates a [SettingsPage] titled [title] over [children].
  const SettingsPage({
    required this.title,
    required this.children,
    this.backLocation = '/settings',
    this.actions,
    super.key,
  });

  /// The page title, shown in the header.
  final String title;

  /// The page content, stacked in a column on the reading column.
  final List<Widget> children;

  /// Where the header's back control navigates.
  final String backLocation;

  /// Trailing header actions.
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        AppSliverHeader(
          title: title,
          backLocation: SettingsScope.twoPaneOf(context) ? null : backLocation,
          actions: actions,
        ),
        SliverToBoxAdapter(
          child: PageBody(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...children,
                // Clears the bottom edge so the last row is not flush with
                // it, matching the breathing room above the header.
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A group label between blocks of Settings rows.
///
/// Small, primary-coloured, and left-aligned with the rows it introduces —
/// the treatment the Settings destination uses for every group so a
/// sub-page's groups read as the same list continued.
class SettingsGroupLabel extends StatelessWidget {
  /// Creates a [SettingsGroupLabel] reading [label].
  const SettingsGroupLabel(this.label, {super.key});

  /// The group heading.
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Explanatory prose under a group of Settings rows.
class SettingsGroupCaption extends StatelessWidget {
  /// Creates a [SettingsGroupCaption] reading [text].
  const SettingsGroupCaption(this.text, {super.key});

  /// The caption.
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

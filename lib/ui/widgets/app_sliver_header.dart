// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/app_shell.dart';
import '../app_theme.dart';

/// A single-row page header sliver for the top-level destinations and the
/// pages they lead to.
///
/// Unlike [SliverAppBar.medium], the title and any [actions] share one row.
/// The background matches the scaffold body so the header runs seamlessly into
/// the page content, with no elevation tint when content scrolls under it.
/// On compact widths, where the shell navigates through a drawer instead of
/// a rail, a leading hamburger button opens that drawer — unless the page is
/// a sub-page, in which case [backLocation] puts a back control there instead.
class AppSliverHeader extends StatelessWidget {
  /// Creates a header showing [title] with optional trailing [actions].
  const AppSliverHeader({
    required this.title,
    this.actions,
    this.backLocation,
    super.key,
  });

  /// The page title.
  final String title;

  /// Trailing action widgets, laid out on the same row as the title.
  final List<Widget>? actions;

  /// Where the leading back control navigates, or null on a destination that
  /// has nothing to go back to.
  ///
  /// Settings sections are sibling routes rather than pushed pages, so there
  /// is nothing to pop — the control navigates to this location explicitly.
  final String? backLocation;

  @override
  Widget build(BuildContext context) {
    final openDrawer = AppShellScope.openDrawerOf(context);
    return SliverAppBar(
      pinned: true,
      // The leading slot is fully managed here; without this, a page whose
      // navigator can pop (a Settings sub-page in the two-pane shell, where
      // the sidebar is the navigation) would get an implied back button.
      automaticallyImplyLeading: false,
      leading: switch ((backLocation, openDrawer)) {
        (final String location, _) => IconButton(
          tooltip: 'Back',
          icon: const AppBackIcon(),
          onPressed: () => context.go(location),
        ),
        (_, final VoidCallback open) => IconButton(
          tooltip: 'Menu',
          icon: const Icon(LucideIcons.menu300),
          onPressed: open,
        ),
        _ => null,
      },
      title: Text(title),
      actions: actions,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      scrolledUnderElevation: 0,
      elevation: 0,
    );
  }
}

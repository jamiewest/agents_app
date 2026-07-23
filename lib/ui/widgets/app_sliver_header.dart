// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../navigation/app_shell.dart';

/// A single-row page header sliver for the top-level destinations.
///
/// Unlike [SliverAppBar.medium], the title and any [actions] share one row.
/// The background matches the scaffold body so the header runs seamlessly into
/// the page content, with no elevation tint when content scrolls under it.
/// On compact widths, where the shell navigates through a drawer instead of
/// a rail, a leading hamburger button opens that drawer.
class AppSliverHeader extends StatelessWidget {
  /// Creates a header showing [title] with optional trailing [actions].
  const AppSliverHeader({required this.title, this.actions, super.key});

  /// The page title.
  final String title;

  /// Trailing action widgets, laid out on the same row as the title.
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final openDrawer = AppShellScope.openDrawerOf(context);
    return SliverAppBar(
      pinned: true,
      leading: openDrawer == null
          ? null
          : IconButton(
              tooltip: 'Menu',
              icon: const Icon(LucideIcons.menu300),
              onPressed: openDrawer,
            ),
      title: Text(title),
      actions: actions,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      scrolledUnderElevation: 0,
      elevation: 0,
    );
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

/// A titled surface the settings dashboards group content in.
///
/// The shared card language across the Agent Center and Logs & diagnostics:
/// a rounded low-emphasis surface with a small heading.
class DashboardCard extends StatelessWidget {
  /// Creates a [DashboardCard].
  const DashboardCard({required this.title, required this.child, super.key});

  /// The card heading.
  final String title;

  /// The card body.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A Material ancestor so ListTile children paint their ink on it rather
    // than warning about the colored container above them.
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

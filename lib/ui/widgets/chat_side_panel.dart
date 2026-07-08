// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_theme.dart';

/// The chat's right-hand utility panel: a titled header with a close
/// button above whatever content the chat wants to surface beside the
/// transcript.
///
/// The panel itself is layout-agnostic — the shell's [SidePanelHost]
/// (see side_panel_host.dart) slides it in over the app when the chat's
/// toggle button opens it.
class ChatSidePanel extends StatelessWidget {
  /// Creates a [ChatSidePanel].
  const ChatSidePanel({
    required this.onClose,
    this.title = 'Details',
    this.child,
    super.key,
  });

  /// Closes the panel (collapses it inline, or dismisses the drawer).
  final VoidCallback onClose;

  /// The header title.
  final String title;

  /// The panel body; a placeholder is shown when null.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close panel',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Symbols.close, size: 20),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child ?? _PanelPlaceholder(scheme: scheme)),
        ],
      ),
    );
  }
}

class _PanelPlaceholder extends StatelessWidget {
  const _PanelPlaceholder({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.right_panel_open, size: 40, color: scheme.outline),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Nothing here yet',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    ),
  );
}

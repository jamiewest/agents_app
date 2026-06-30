// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:flutter/material.dart';

import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';

/// Generates a reasonably unique identifier for a new configuration entity.
///
/// Combines a millisecond timestamp with random entropy; ids only need to be
/// unique within a single app's stored configuration, not globally.
String newConfiguredAgentsId() {
  final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final suffix = Random().nextInt(0xFFFFFFFF).toRadixString(36);
  return '$now-$suffix';
}

/// The cancel/save button row shared by every configured-agents editor.
class EditorActions extends StatelessWidget {
  /// Creates an [EditorActions] row.
  const EditorActions({
    required this.style,
    required this.strings,
    required this.onCancel,
    required this.onSave,
    super.key,
  });

  /// Resolved style.
  final ConfiguredAgentsStyle style;

  /// Resolved strings.
  final ConfiguredAgentsStrings strings;

  /// Invoked when the user cancels.
  final VoidCallback onCancel;

  /// Invoked when the user saves.
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(onPressed: onCancel, child: Text(strings.cancel)),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onSave,
          style: style.accentColor == null
              ? null
              : FilledButton.styleFrom(backgroundColor: style.accentColor),
          child: Text(strings.save),
        ),
      ],
    );
  }
}

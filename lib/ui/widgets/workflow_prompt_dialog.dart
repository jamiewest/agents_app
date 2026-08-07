// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Asks which prompt to run a workflow against, prefilled with the
/// workflow's saved prompt.
///
/// Returns the entered prompt, or null when cancelled. Callers persist
/// any edit back onto the workflow so each workflow keeps its own prompt.
Future<String?> showWorkflowPromptDialog(
  BuildContext context, {
  required String initialPrompt,
}) {
  final controller = TextEditingController(text: initialPrompt);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Run workflow'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'Prompt',
          helperText: 'Saved with this workflow.',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, controller.text),
          icon: const Icon(LucideIcons.play300, size: 18),
          label: const Text('Run'),
        ),
      ],
    ),
  );
}

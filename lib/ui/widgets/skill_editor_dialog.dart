// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart' show AgentSkillFrontmatter;
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';

/// Shows the skill create/edit dialog.
///
/// Returns the built [StoredSkill], or `null` when cancelled; the caller
/// persists it. Pass [initial] to edit — its id and creation time are
/// preserved. [existingNames] are the names the new skill must not collide
/// with (when editing, exclude the skill's own name).
Future<StoredSkill?> showSkillEditorDialog(
  BuildContext context, {
  required String Function() newId,
  Set<String> existingNames = const {},
  StoredSkill? initial,
}) => showDialog<StoredSkill>(
  context: context,
  builder: (context) => _SkillEditorDialog(
    newId: newId,
    existingNames: existingNames,
    initial: initial,
  ),
);

class _SkillEditorDialog extends StatefulWidget {
  const _SkillEditorDialog({
    required this.newId,
    required this.existingNames,
    this.initial,
  });

  final String Function() newId;
  final Set<String> existingNames;
  final StoredSkill? initial;

  @override
  State<_SkillEditorDialog> createState() => _SkillEditorDialogState();
}

class _SkillEditorDialogState extends State<_SkillEditorDialog> {
  late final _nameController = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final _descriptionController = TextEditingController(
    text: widget.initial?.description ?? '',
  );
  late final _instructionsController = TextEditingController(
    text: widget.initial?.instructions ?? '',
  );

  bool get _editing => widget.initial != null;

  /// Why the current name is unusable, or `null` while it is empty (the
  /// Save button stays disabled without shouting at a blank form) or valid.
  String? get _nameError {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;
    final (valid, reason) = AgentSkillFrontmatter.validateName(name);
    if (!valid) return reason;
    if (widget.existingNames.contains(name)) {
      return 'A skill with this name already exists.';
    }
    return null;
  }

  String? get _descriptionError {
    final description = _descriptionController.text.trim();
    if (description.isEmpty) return null;
    final (valid, reason) = AgentSkillFrontmatter.validateDescription(
      description,
    );
    return valid ? null : reason;
  }

  bool get _valid =>
      _nameController.text.trim().isNotEmpty &&
      _descriptionController.text.trim().isNotEmpty &&
      _instructionsController.text.trim().isNotEmpty &&
      _nameError == null &&
      _descriptionError == null;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_valid) return;
    final initial = widget.initial;
    final now = DateTime.now();
    Navigator.of(context).pop(
      StoredSkill(
        id: initial?.id ?? widget.newId(),
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        instructions: _instructionsController.text.trim(),
        createdAt: initial?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing ? 'Edit skill' : 'Create skill',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(LucideIcons.x300),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AppSpacing.lg,
                    children: [
                      TextField(
                        controller: _nameController,
                        autofocus: !_editing,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Name',
                          hintText: 'commit-message-style',
                          helperText:
                              'Lowercase letters, numbers, and hyphens.',
                          errorText: _nameError,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      TextField(
                        controller: _descriptionController,
                        minLines: 2,
                        maxLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: 'When to use it',
                          hintText:
                              'What the skill does and when an agent '
                              'should reach for it.',
                          errorText: _descriptionError,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      _InstructionsField(
                        controller: _instructionsController,
                        onChanged: (_) => setState(() {}),
                      ),
                      Text(
                        'Agents see the name and description on every turn; '
                        'the instructions load only when the skill is used.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: AppSpacing.sm,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _valid ? _submit : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The instructions editor: a borderless multiline field inside one framed
/// surface, matching the task editor's prompt field.
class _InstructionsField extends StatelessWidget {
  const _InstructionsField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppShape.inner),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: TextField(
        controller: controller,
        minLines: 6,
        maxLines: 12,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'The instructions the agent follows when using the skill.',
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.all(AppSpacing.lg),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

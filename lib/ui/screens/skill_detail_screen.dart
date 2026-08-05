// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';
import '../widgets/conversation_actions.dart';
import '../widgets/empty_state.dart';
import '../widgets/skill_editor_dialog.dart';

/// One skill's page: when agents use it and the instructions they follow.
/// Edit and delete live here.
class SkillDetailScreen extends StatefulWidget {
  /// Creates a [SkillDetailScreen].
  const SkillDetailScreen({
    required this.services,
    required this.skillId,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// The skill to show.
  final String skillId;

  @override
  State<SkillDetailScreen> createState() => _SkillDetailScreenState();
}

class _SkillDetailScreenState extends State<SkillDetailScreen> {
  late final SkillStore _skills;

  @override
  void initState() {
    super.initState();
    _skills = widget.services.getRequiredService<SkillStore>();
  }

  Future<void> _editSkill(StoredSkill skill) async {
    final existing = await _skills.list();
    if (!mounted) return;
    final edited = await showSkillEditorDialog(
      context,
      newId: _skills.newSkillId,
      existingNames: {
        for (final other in existing)
          if (other.id != skill.id) other.name,
      },
      initial: skill,
    );
    if (edited != null) await _skills.save(edited);
  }

  Future<void> _deleteSkill(StoredSkill skill) async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete skill?',
      message:
          'Delete "${skill.name}"? Agents will no longer be able to use it.',
      confirmLabel: 'Delete skill',
    );
    if (!confirmed) return;
    await _skills.delete(skill.id);
    if (mounted) context.go('/skills');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: StreamBuilder<List<StoredSkill>>(
      stream: _skills.watchAll(),
      builder: (context, snapshot) {
        final skills = snapshot.data;
        if (skills == null) {
          return const Center(child: CircularProgressIndicator());
        }
        StoredSkill? skill;
        for (final candidate in skills) {
          if (candidate.id == widget.skillId) skill = candidate;
        }
        if (skill == null) return _missing(context);
        return _SkillDetailBody(
          skill: skill,
          onEdit: () => _editSkill(skill!),
          onDelete: () => _deleteSkill(skill!),
        );
      },
    ),
  );

  Widget _missing(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar(
        pinned: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      const SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: LucideIcons.sparkles300,
          title: 'Skill not found',
          message: 'This skill was deleted.',
        ),
      ),
    ],
  );
}

class _SkillDetailBody extends StatelessWidget {
  const _SkillDetailBody({
    required this.skill,
    required this.onEdit,
    required this.onDelete,
  });

  final StoredSkill skill;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static String _timestamp(DateTime time) =>
      time.toLocal().toString().substring(0, 16);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: theme.scaffoldBackgroundColor,
          scrolledUnderElevation: 0,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(LucideIcons.trash2300),
              onPressed: onDelete,
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton.icon(
              onPressed: onEdit,
              icon: const Icon(LucideIcons.pencil300, size: 18),
              label: const Text('Edit'),
            ),
            const SizedBox(width: AppSpacing.lg),
          ],
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(skill.name, style: theme.textTheme.headlineMedium),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Agents with skills enabled see this skill and load '
                      'its instructions when the description fits the job.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                    const Divider(),
                    _Section(
                      label: 'When to use',
                      child: Text(
                        skill.description,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    _Section(
                      label: 'Instructions',
                      child: Text(
                        skill.instructions,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    _Section(
                      label: 'History',
                      child: Text(
                        'Created ${_timestamp(skill.createdAt)} • '
                        'Updated ${_timestamp(skill.updatedAt)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A labeled block in the detail column: muted heading, content below.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.sm,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

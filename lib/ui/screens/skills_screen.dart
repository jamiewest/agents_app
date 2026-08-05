// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';
import '../widgets/app_sliver_header.dart';
import '../widgets/empty_state.dart';
import '../widgets/skill_editor_dialog.dart';

/// The Skills destination: reusable instructions agents load on demand.
///
/// Skills come from two directions — created here by hand, or written by an
/// agent through the `create_skill` tool — and either way they land in the
/// same store, so a skill an agent authored mid-conversation shows up here
/// ready to edit.
class SkillsScreen extends StatefulWidget {
  /// Creates a [SkillsScreen].
  const SkillsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late final SkillStore _skills;

  @override
  void initState() {
    super.initState();
    // Resolved from DI rather than built ad hoc: this is the same instance
    // the conversation wiring hands the agents.
    _skills = widget.services.getRequiredService<SkillStore>();
  }

  Future<void> _createSkill() async {
    final existing = await _skills.list();
    if (!mounted) return;
    final created = await showSkillEditorDialog(
      context,
      newId: _skills.newSkillId,
      existingNames: {for (final skill in existing) skill.name},
    );
    if (created != null) await _skills.save(created);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return Scaffold(
      body: StreamBuilder<List<StoredSkill>>(
        stream: _skills.watchAll(),
        builder: (context, snapshot) {
          final skills = snapshot.data;
          return CustomScrollView(
            slivers: [
              AppSliverHeader(
                title: 'Skills',
                actions: [
                  if (compact)
                    IconButton(
                      tooltip: 'New skill',
                      icon: const Icon(LucideIcons.plus300),
                      onPressed: _createSkill,
                    )
                  else
                    FilledButton.icon(
                      onPressed: _createSkill,
                      icon: const Icon(LucideIcons.plus300, size: 18),
                      label: const Text('New skill'),
                    ),
                  const SizedBox(width: AppSpacing.lg),
                ],
              ),
              _centered(
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                  child: Text(
                    'Teach your agents reusable skills — or ask an agent to '
                    'create one for you.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (skills == null)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.xxxl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else ...[
                _skillListSliver(skills),
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.xxxl),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Wraps [child] in the page's centered 720-wide content column.
  Widget _centered(Widget child) => SliverToBoxAdapter(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: child,
        ),
      ),
    ),
  );

  Widget _skillListSliver(List<StoredSkill> skills) {
    if (skills.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
          child: EmptyState(
            icon: LucideIcons.sparkles300,
            title: 'No skills yet.',
            message:
                'Create one here, or ask an agent to create one in a chat.',
          ),
        ),
      );
    }
    return _centered(
      LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 560;
          final width = twoColumns
              ? (constraints.maxWidth - AppSpacing.lg) / 2
              : constraints.maxWidth;
          return Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.lg,
            children: [
              for (final skill in skills)
                SizedBox(
                  width: width,
                  child: _SkillCard(skill: skill),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One skill in the list: its name and when to use it. Tapping opens the
/// skill's detail page.
class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.skill});

  final StoredSkill skill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppShape.card),
        onTap: () => context.go('/skills/s/${skill.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppSpacing.sm,
            children: [
              Text(
                skill.name,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                skill.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

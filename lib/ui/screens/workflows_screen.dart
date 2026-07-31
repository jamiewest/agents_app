// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents/agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/workflows/demo_workflows.dart';
import '../../features/workflows/role_agent.dart';
import '../../features/workflows/workflow_launcher.dart';
import '../../features/workflows/workflow_run_controller.dart';
import '../../features/workflows/workflow_spec.dart';
import '../../features/workflows/workflow_spec_store.dart';
import '../app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/app_sliver_header.dart';
import '../widgets/page_body.dart';
import '../widgets/workflow_run_inspector.dart';

/// The orchestration patterns the demo can run.
enum _WorkflowPattern {
  sequential(
    'Sequential',
    'A Drafter answers first, then an Editor reviews and improves it.',
  ),
  concurrent(
    'Concurrent',
    'An Optimist and a Skeptic answer in parallel; their takes are merged.',
  ),
  reviewed(
    'Reviewed',
    'A Drafter answers, the run pauses for your feedback, and an Editor '
        'applies it.',
  );

  const _WorkflowPattern(this.label, this.blurb);

  /// Segmented-button label.
  final String label;

  /// One-line description under the picker.
  final String blurb;
}

/// The Workflows destination: compose a small multi-agent workflow from a
/// configured agent and watch it run.
///
/// This is the first slice of the workflow tech in `package:agents`: a
/// pattern picker builds a real [Workflow], and the inspector below renders
/// the live graph, per-stage streamed output, the event log, and any
/// human-in-the-loop requests.
class WorkflowsScreen extends StatefulWidget {
  /// Creates a [WorkflowsScreen].
  const WorkflowsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<WorkflowsScreen> createState() => _WorkflowsScreenState();
}

class _WorkflowsScreenState extends State<WorkflowsScreen> {
  late final Future<List<SavedAgentConfig>> _agentsFuture;
  final TextEditingController _prompt = TextEditingController(
    text: 'Suggest a name for a coffee shop run by robots.',
  );
  _WorkflowPattern _pattern = _WorkflowPattern.sequential;
  String? _agentId;
  WorkflowRunController? _run;
  bool _starting = false;

  /// The saved spec behind the active run, for checkpoint replays.
  WorkflowSpec? _lastSpec;

  late final WorkflowSpecStore _workflows;

  @override
  void initState() {
    super.initState();
    _agentsFuture = widget.services
        .getRequiredService<ConfiguredAgentsManager>()
        .agents
        .listAgents();
    _workflows = WorkflowSpecStore(
      widget.services.getRequiredService<RecordStore>(),
    );
  }

  @override
  void dispose() {
    _prompt.dispose();
    _run?.dispose();
    super.dispose();
  }

  /// Whether a run is active (started and not yet finished).
  bool get _runActive => switch (_run) {
    null => false,
    final run => !run.isFinished,
  };

  Future<void> _startRun(String agentId) async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty || _starting || _runActive) return;
    setState(() => _starting = true);
    try {
      final factory = widget.services
          .getRequiredService<ConfiguredAgentFactory>();
      Future<RoleAgent> role(String name, String instructions) async =>
          RoleAgent(
            await factory.createAgentById(agentId),
            role: name,
            roleInstructions: instructions,
          );
      final workflow = switch (_pattern) {
        _WorkflowPattern.sequential => DemoWorkflows.sequential([
          await role(
            'Drafter',
            'You are the first stage of a two-stage pipeline. Draft a '
                'direct, complete answer to the request. Keep it brief.',
          ),
          await role(
            'Editor',
            'You are the final stage of a two-stage pipeline. Review the '
                'draft above and reply with an improved final answer '
                'only. Keep it brief.',
          ),
        ], name: 'Draft, then edit'),
        _WorkflowPattern.concurrent => DemoWorkflows.concurrent([
          await role(
            'Optimist',
            'Answer the request emphasizing the best ideas and '
                'opportunities. Keep it brief.',
          ),
          await role(
            'Skeptic',
            'Answer the request emphasizing risks, pitfalls, and '
                'counterpoints. Keep it brief.',
          ),
        ], name: 'Answer in parallel'),
        _WorkflowPattern.reviewed => DemoWorkflows.reviewed([
          await role(
            'Drafter',
            'You are the first stage of a pipeline. Draft a direct, '
                'complete answer to the request. Keep it brief.',
          ),
          await role(
            'Editor',
            'You are the final stage of a pipeline. Revise the draft '
                'according to the reviewer feedback and reply with the '
                'final answer only. Keep it brief.',
          ),
        ], name: 'Draft, review, edit'),
      };
      _lastSpec = null;
      final previous = _run;
      final controller = WorkflowRunController(
        workflow: workflow,
        encodeResponse: DemoWorkflows.encodeResponse,
      );
      setState(() => _run = controller);
      previous?.dispose();
      await controller.start(prompt);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not start run: $error')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Stops watching the active run so a new one can start.
  ///
  /// The engine offers no mid-run cancel; discarding detaches the
  /// inspector and lets the abandoned run finish on its own.
  void _discardRun() {
    final run = _run;
    setState(() => _run = null);
    run?.dispose();
  }

  /// Runs a saved workflow right here, without opening the editor.
  Future<void> _runSavedSpec(WorkflowSpec spec) async {
    if (_starting || _runActive) return;
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) return;
    setState(() => _starting = true);
    try {
      _lastSpec = spec;
      final controller = await createSpecRunController(
        widget.services,
        spec,
      );
      final previous = _run;
      setState(() => _run = controller);
      previous?.dispose();
      await controller.start(prompt);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not start run: $error')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Replays the last saved-workflow run from [checkpoint].
  Future<void> _replayCheckpoint(Checkpoint checkpoint) async {
    final spec = _lastSpec;
    final finished = _run;
    if (spec == null || finished == null || _starting) return;
    setState(() => _starting = true);
    try {
      final controller = await createSpecRunController(
        widget.services,
        spec,
        checkpoints: finished.checkpoints,
      );
      setState(() => _run = controller);
      finished.dispose();
      await controller.startFromCheckpoint(checkpoint.info);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not replay: $error')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget _pageColumn(
    BuildContext context,
    List<SavedAgentConfig> agents, {
    required WorkflowRunController? run,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Compose a small multi-agent workflow and watch it run.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      _SavedWorkflowsSection(
        store: _workflows,
        busy: _starting || _runActive,
        onRun: (spec) => _runSavedSpec(spec),
      ),
      const SizedBox(height: AppSpacing.lg),
      Text('Quick demos', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: AppSpacing.sm),
      _SetupCard(
        agents: agents,
        agentId: _agentId ?? agents.first.id,
        pattern: _pattern,
        prompt: _prompt,
        busy: _starting || _runActive,
        onAgentChanged: (id) => setState(() => _agentId = id),
        onPatternChanged: (pattern) => setState(() => _pattern = pattern),
        onRun: () => _startRun(_agentId ?? agents.first.id),
      ),
      if (run != null) ...[
        const SizedBox(height: AppSpacing.lg),
        WorkflowRunInspector(
          run: run,
          onDiscard: _discardRun,
          onReplayCheckpoint: _lastSpec == null
              ? null
              : (checkpoint) => unawaited(_replayCheckpoint(checkpoint)),
        ),
      ],
      const SizedBox(height: AppSpacing.xl),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<List<SavedAgentConfig>>(
      future: _agentsFuture,
      builder: (context, snapshot) {
        final agents = snapshot.data;
        return CustomScrollView(
          slivers: [
            const AppSliverHeader(title: 'Workflows'),
            if (agents == null)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (agents.isEmpty)
              SliverFillRemaining(
                child: EmptyState(
                  icon: LucideIcons.workflow300,
                  title: 'Workflows need an agent',
                  message:
                      'Add an agent first; workflows cast it into '
                      'multiple roles.',
                  actionLabel: 'Add agent',
                  onAction: () => context.go('/settings/agents/add'),
                ),
              )
            else
              SliverToBoxAdapter(
                child: PageBody(
                  // One ListenableBuilder wraps setup and inspector alike:
                  // the Run button's enabled state tracks the live run, not
                  // just setState.
                  child: switch (_run) {
                    null => _pageColumn(context, agents, run: null),
                    final run => ListenableBuilder(
                      listenable: run,
                      builder: (context, _) =>
                          _pageColumn(context, agents, run: run),
                    ),
                  },
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// The pattern/agent/prompt form that starts a run.
class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.agents,
    required this.agentId,
    required this.pattern,
    required this.prompt,
    required this.busy,
    required this.onAgentChanged,
    required this.onPatternChanged,
    required this.onRun,
  });

  final List<SavedAgentConfig> agents;
  final String agentId;
  final _WorkflowPattern pattern;
  final TextEditingController prompt;
  final bool busy;
  final ValueChanged<String> onAgentChanged;
  final ValueChanged<_WorkflowPattern> onPatternChanged;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkflowSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<_WorkflowPattern>(
            segments: [
              for (final pattern in _WorkflowPattern.values)
                ButtonSegment(value: pattern, label: Text(pattern.label)),
            ],
            selected: {pattern},
            onSelectionChanged: busy
                ? null
                : (selection) => onPatternChanged(selection.single),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            pattern.blurb,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          DropdownButtonFormField<String>(
            initialValue: agentId,
            decoration: const InputDecoration(
              labelText: 'Agent',
              helperText: 'One agent plays every role.',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final agent in agents)
                DropdownMenuItem(value: agent.id, child: Text(agent.name)),
            ],
            onChanged: busy
                ? null
                : (id) {
                    if (id != null) onAgentChanged(id);
                  },
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: prompt,
            enabled: !busy,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Prompt',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => onRun(),
          ),
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: busy ? null : onRun,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.play300, size: 18),
              label: Text(busy ? 'Running…' : 'Run workflow'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The saved-workflows list: open in the editor, create, or delete.
class _SavedWorkflowsSection extends StatelessWidget {
  const _SavedWorkflowsSection({
    required this.store,
    required this.busy,
    required this.onRun,
  });

  final WorkflowSpecStore store;
  final bool busy;
  final ValueChanged<WorkflowSpec> onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkflowSectionCard(
      title: 'Your workflows',
      trailing: MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          for (final template in WorkflowTemplate.values)
            MenuItemButton(
              onPressed: () => context.go(
                '/workflows/edit/${store.newId()}'
                '?template=${template.name}',
              ),
              child: Text(template.label),
            ),
        ],
        builder: (context, menu, _) => FilledButton.tonalIcon(
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(LucideIcons.plus300, size: 18),
          label: const Text('New workflow'),
        ),
      ),
      child: StreamBuilder<List<WorkflowSpec>>(
        stream: store.watchAll(),
        builder: (context, snapshot) {
          final specs = snapshot.data;
          if (specs == null) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (specs.isEmpty) {
            return Text(
              'Nothing saved yet. Build one on the canvas: add agents, '
              'review gates, and merges, then connect them.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final spec in specs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(LucideIcons.workflow300, size: 20),
                  title: Text(spec.name),
                  subtitle: Text(
                    '${spec.nodes.length} nodes · '
                    '${spec.edges.length} connections',
                  ),
                  onTap: () => context.go('/workflows/edit/${spec.id}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Run with the prompt below',
                        icon: const Icon(LucideIcons.play300, size: 18),
                        onPressed: busy ? null : () => onRun(spec),
                      ),
                      IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(LucideIcons.trash2300, size: 18),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('Delete "${spec.name}"?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed ?? false) await store.delete(spec.id);
                    },
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

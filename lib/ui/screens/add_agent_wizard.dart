// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/local_model_presets.dart';
import '../app_theme.dart';
import '../strings/configured_agents_strings.dart';
import '../widgets/page_body.dart';
import '../styles/configured_agents_style.dart';
import '../views/configured_agents/agent_editor.dart';
import '../views/configured_agents/model_editor.dart';
import '../views/configured_agents/source_editor.dart';

/// Guided three-step setup for a new agent: provider source, model, agent.
///
/// The single entry point for adding agents of any kind; network (A2A)
/// agents join this flow as a source option when pairing ships. Reuses the
/// standalone editors from the management surface.
class AddAgentWizard extends StatefulWidget {
  /// Creates an [AddAgentWizard].
  const AddAgentWizard({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<AddAgentWizard> createState() => _AddAgentWizardState();
}

class _AddAgentWizardState extends State<AddAgentWizard> {
  static const _stepTitles = ['Provider', 'Model', 'Agent'];

  late final ConfiguredAgentsManager _manager;
  int _step = 0;
  ModelSourceConfig? _source;
  ModelConfig? _model;
  ModelConfig? _presetModel;

  @override
  void initState() {
    super.initState();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
  }

  void _exit() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }

  void _back() {
    if (_step == 0) {
      _exit();
    } else {
      setState(() => _step--);
    }
  }

  Future<void> _submitSource(ModelSourceConfig source, String? apiKey) async {
    await _manager.saveSource(source, apiKey: apiKey);
    if (!mounted) return;
    setState(() {
      _source = source;
      _step = 1;
    });
  }

  Future<void> _submitModel(ModelConfig model) async {
    await _manager.saveModel(model);
    if (!mounted) return;
    setState(() {
      _model = model;
      _step = 2;
    });
  }

  Future<void> _submitAgent(SavedAgentConfig agent) async {
    await _manager.saveAgent(agent);
    if (!mounted) return;
    context.go('/chats/new/${agent.id}');
  }

  @override
  Widget build(BuildContext context) {
    final style = ConfiguredAgentsStyle.resolveFor(context, null);
    const strings = ConfiguredAgentsStrings.defaults;

    return Scaffold(
      appBar: AppBar(
        title: Text('Add agent — ${_stepTitles[_step]}'),
        leading: IconButton(
          tooltip: _step == 0 ? 'Cancel' : 'Back',
          icon: const AppBackIcon(),
          onPressed: _back,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _StepIndicator(step: _step, titles: _stepTitles),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: PageBody(
                child: switch (_step) {
                  0 => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.lan_outlined),
                          title: const Text('Network agent instead?'),
                          subtitle: const Text(
                            'Add an agent shared by another device with a '
                            'pairing code.',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.go('/settings/network/pair'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SourceEditor(
                        style: style,
                        strings: strings,
                        onSubmit: (source, apiKey) =>
                            unawaited(_submitSource(source, apiKey)),
                        onCancel: _exit,
                      ),
                    ],
                  ),
                  1 => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_source!.providerType == ProviderType.localLlama) ...[
                        Text(
                          'Start from a known-good model',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in localModelPresets)
                              Tooltip(
                                message: preset.subtitle,
                                child: ActionChip(
                                  label: Text(preset.name),
                                  onPressed: () => setState(() {
                                    _presetModel = preset.toModelConfig(
                                      id:
                                          'model-'
                                          '${DateTime.now().microsecondsSinceEpoch}',
                                      sourceId: _source!.id,
                                    );
                                  }),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      ModelEditor(
                        key: ValueKey(_presetModel?.id ?? 'blank'),
                        initial: _presetModel,
                        sources: [_source!],
                        style: style,
                        strings: strings,
                        onSubmit: (model) => unawaited(_submitModel(model)),
                        onCancel: _back,
                      ),
                    ],
                  ),
                  _ => AgentEditor(
                    models: [_model!],
                    style: style,
                    strings: strings,
                    onSubmit: (agent) => unawaited(_submitAgent(agent)),
                    onCancel: _back,
                  ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Numbered step chips for the wizard header.
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step, required this.titles});

  final int step;
  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < titles.length; i++) ...[
          if (i > 0)
            Container(
              width: 28,
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: scheme.outlineVariant,
            ),
          CircleAvatar(
            radius: 13,
            backgroundColor: i <= step
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            child: i < step
                ? Icon(Icons.check, size: 15, color: scheme.onPrimary)
                : Text(
                    '${i + 1}',
                    style: labelStyle?.copyWith(
                      color: i <= step
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Text(
            titles[i],
            style: labelStyle?.copyWith(
              color: i == step ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

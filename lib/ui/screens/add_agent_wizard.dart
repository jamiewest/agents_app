// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../strings/configured_agents_strings.dart';
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
          icon: const Icon(Icons.arrow_back),
          onPressed: _back,
        ),
      ),
      body: Column(
        children: [
          LinearProgressIndicator(value: (_step + 1) / _stepTitles.length),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: switch (_step) {
                0 => SourceEditor(
                  style: style,
                  strings: strings,
                  onSubmit: (source, apiKey) =>
                      unawaited(_submitSource(source, apiKey)),
                  onCancel: _exit,
                ),
                1 => ModelEditor(
                  sources: [_source!],
                  style: style,
                  strings: strings,
                  onSubmit: (model) => unawaited(_submitModel(model)),
                  onCancel: _back,
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
        ],
      ),
    );
  }
}

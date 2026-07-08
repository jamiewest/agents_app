// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../data/local_model_presets.dart';
import '../app_theme.dart';
import '../strings/configured_agents_strings.dart';
import '../widgets/page_body.dart';
import '../styles/configured_agents_style.dart';
import '../views/configured_agents/agent_editor.dart';
import '../views/configured_agents/editor_actions.dart';
import '../views/configured_agents/model_editor.dart';
import '../views/configured_agents/source_editor.dart';

/// The kind of agent the add-agent wizard is setting up.
///
/// Network agents pair through their own screen instead of the wizard, so
/// they have no kind here.
enum AgentSetupKind {
  /// A hosted model behind an API key (Anthropic, Google, OpenAI-compatible).
  api,

  /// A GGUF model running on this device via llama.cpp.
  local,
}

/// Parses a `?type=` query value into a kind, or null when absent/unknown.
AgentSetupKind? agentSetupKindFromName(String? name) => switch (name) {
  'api' => AgentSetupKind.api,
  'local' => AgentSetupKind.local,
  _ => null,
};

/// Guided, type-specific setup for a new agent.
///
/// The flow depends on the kind of agent being added:
///
/// * API: provider (endpoint + key) → model → agent.
/// * Local: model (with known-good presets) → agent. The local source has
///   nothing to configure, so it is created (or reused) automatically and
///   the provider step is skipped.
/// * Network: handled by the pairing screen; the in-wizard chooser links
///   to it.
///
/// When [initialKind] is null (e.g. opened from Settings), the wizard first
/// asks which kind to add; onboarding passes the kind the user already
/// chose so the question is never asked twice.
class AddAgentWizard extends StatefulWidget {
  /// Creates an [AddAgentWizard].
  const AddAgentWizard({required this.services, this.initialKind, super.key});

  /// The application service provider.
  final ServiceProvider services;

  /// The kind chosen before opening the wizard, or null to ask first.
  final AgentSetupKind? initialKind;

  @override
  State<AddAgentWizard> createState() => _AddAgentWizardState();
}

class _AddAgentWizardState extends State<AddAgentWizard> {
  late final ConfiguredAgentsManager _manager;
  AgentSetupKind? _kind;
  int _step = 0;
  ModelSourceConfig? _source;
  ModelConfig? _model;
  ModelConfig? _presetModel;

  /// The agent-step prefill, created once per saved model so rebuilds and
  /// repeated submits keep one stable agent id.
  SavedAgentConfig? _agentDraft;

  @override
  void initState() {
    super.initState();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    _kind = widget.initialKind;
    if (_kind == AgentSetupKind.local) unawaited(_prepareLocalSource());
  }

  List<String> get _stepTitles => switch (_kind) {
    AgentSetupKind.api => const ['Provider', 'Model', 'Agent'],
    AgentSetupKind.local => const ['Model', 'Agent'],
    null => const [],
  };

  int get _agentStep => _kind == AgentSetupKind.api ? 2 : 1;

  void _exit() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }

  /// Whether the wizard is mounted on the full-screen onboarding route
  /// rather than inside the settings shell.
  bool get _inOnboarding =>
      GoRouterState.of(context).matchedLocation.startsWith('/onboarding');

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
      return;
    }
    // At the kind's first step: return to the in-wizard chooser when the
    // kind was picked here, otherwise leave the wizard.
    if (_kind != null && widget.initialKind == null) {
      setState(() {
        _kind = null;
        _source = null;
        _model = null;
        _presetModel = null;
      });
      return;
    }
    _exit();
  }

  void _selectKind(AgentSetupKind kind) {
    setState(() {
      _kind = kind;
      _step = 0;
    });
    if (kind == AgentSetupKind.local) unawaited(_prepareLocalSource());
  }

  /// Shows [error] instead of letting a failed save die silently in an
  /// unawaited future (e.g. a keychain write rejected by the platform).
  void _showSaveError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not save: $error'), showCloseIcon: true),
    );
  }

  /// Reuses the existing local source, or creates one; local sources carry
  /// no user-facing configuration, so there is nothing to ask.
  Future<void> _prepareLocalSource() async {
    try {
      final sources = await _manager.sources.listSources();
      ModelSourceConfig? source;
      for (final candidate in sources) {
        if (candidate.providerType == ProviderType.localLlama) {
          source = candidate;
          break;
        }
      }
      if (source == null) {
        source = ModelSourceConfig(
          id: newConfiguredAgentsId(),
          providerType: ProviderType.localLlama,
          displayName: 'This device',
        );
        await _manager.saveSource(source);
      }
      if (!mounted) return;
      setState(() => _source = source);
    } catch (error) {
      _showSaveError(error);
    }
  }

  Future<void> _submitSource(ModelSourceConfig source, String? apiKey) async {
    try {
      await _manager.saveSource(source, apiKey: apiKey);
    } catch (error) {
      _showSaveError(error);
      return;
    }
    if (!mounted) return;
    setState(() {
      _source = source;
      _step = 1;
    });
  }

  Future<void> _submitModel(ModelConfig model) async {
    try {
      await _manager.saveModel(model);
    } catch (error) {
      _showSaveError(error);
      return;
    }
    if (!mounted) return;
    // Prefill the agent name from the model so accepting the defaults is
    // one tap; local models without a display name expose an internal id
    // as modelId, which would make a poor name, so leave those blank.
    final suggestedName = model.displayName?.trim().isNotEmpty ?? false
        ? model.displayName!.trim()
        : (model.modelId == model.id ? '' : model.modelId);
    setState(() {
      _model = model;
      _agentDraft = SavedAgentConfig(
        id: newConfiguredAgentsId(),
        name: suggestedName,
        modelId: model.id,
      );
      _step = _agentStep;
    });
  }

  Future<void> _submitAgent(SavedAgentConfig agent) async {
    try {
      await _manager.saveAgent(agent);
    } catch (error) {
      _showSaveError(error);
      return;
    }
    if (!mounted) return;
    context.go('/chats/new/${agent.id}');
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final titles = _stepTitles;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          kind == null ? 'Add agent' : 'Add agent — ${titles[_step]}',
        ),
        leading: IconButton(
          tooltip: _step == 0 && (kind == null || widget.initialKind != null)
              ? 'Cancel'
              : 'Back',
          icon: const AppBackIcon(),
          onPressed: _back,
        ),
      ),
      body: Column(
        children: [
          if (kind != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _StepIndicator(step: _step, titles: titles),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: PageBody(
                child: kind == null
                    ? _KindChooser(
                        onSelect: _selectKind,
                        onNetwork: () => context.go(
                          _inOnboarding
                              ? '/onboarding/pair'
                              : '/settings/network/pair',
                        ),
                      )
                    : _buildStep(context, kind),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(BuildContext context, AgentSetupKind kind) {
    final style = ConfiguredAgentsStyle.resolveFor(context, null);
    const strings = ConfiguredAgentsStrings.defaults;
    final modelStep = kind == AgentSetupKind.api ? 1 : 0;

    if (kind == AgentSetupKind.api && _step == 0) {
      return SourceEditor(
        style: style,
        strings: strings,
        providerTypes: const [
          ProviderType.anthropic,
          ProviderType.google,
          ProviderType.openAiCompatible,
        ],
        onSubmit: (source, apiKey) => unawaited(_submitSource(source, apiKey)),
        onCancel: _back,
      );
    }

    if (_step == modelStep) {
      final source = _source;
      // The local source is created asynchronously on entry.
      if (source == null) {
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (source.providerType == ProviderType.localLlama) ...[
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
                          sourceId: source.id,
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
            sources: [source],
            style: style,
            strings: strings,
            onSubmit: (model) => unawaited(_submitModel(model)),
            onCancel: _back,
          ),
        ],
      );
    }

    return AgentEditor(
      models: [_model!],
      initial: _agentDraft,
      style: style,
      strings: strings,
      onSubmit: (agent) => unawaited(_submitAgent(agent)),
      onCancel: _back,
    );
  }
}

/// The "what kind of agent?" step shown when the wizard is opened without
/// a preselected kind.
class _KindChooser extends StatelessWidget {
  const _KindChooser({required this.onSelect, required this.onNetwork});

  final ValueChanged<AgentSetupKind> onSelect;
  final VoidCallback onNetwork;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _KindCard(
        icon: Symbols.cloud,
        title: 'API agent',
        subtitle:
            'Anthropic, Google, or any OpenAI-compatible endpoint. '
            'Needs an API key.',
        onTap: () => onSelect(AgentSetupKind.api),
      ),
      const SizedBox(height: 12),
      _KindCard(
        icon: Symbols.memory,
        title: 'Local agent',
        subtitle:
            'Runs a downloaded model on this device. No key required, '
            'works offline.',
        onTap: () => onSelect(AgentSetupKind.local),
      ),
      const SizedBox(height: 12),
      _KindCard(
        icon: Symbols.lan,
        title: 'Network agent',
        subtitle:
            'Use an agent shared by another device. Pair with a code; '
            'it joins your agent list.',
        onTap: onNetwork,
      ),
    ],
  );
}

class _KindCard extends StatelessWidget {
  const _KindCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon, size: 32),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Symbols.chevron_right),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    ),
  );
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
                ? Icon(Symbols.check, size: 15, color: scheme.onPrimary)
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

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';
import 'configured_agents_form_field.dart';
import 'editor_actions.dart';

/// Editor form for creating or updating a [SavedAgentConfig].
class AgentEditor extends StatefulWidget {
  /// Creates an [AgentEditor].
  const AgentEditor({
    required this.models,
    required this.style,
    required this.strings,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.agents = const [],
    this.networkModelIds = const {},
    super.key,
  });

  /// The agent being edited, or `null` to create a new one.
  final SavedAgentConfig? initial;

  /// Models the agent may run on. Must be non-empty.
  final List<ModelConfig> models;

  /// Saved agents offered as delegate targets. The agent being edited is
  /// excluded automatically.
  final List<SavedAgentConfig> agents;

  /// Ids of models backed by remote network agents.
  ///
  /// Remote agents run inside their host's harness, so local tool access
  /// and delegation settings do not apply and are hidden for them.
  final Set<String> networkModelIds;

  /// Resolved style.
  final ConfiguredAgentsStyle style;

  /// Resolved strings.
  final ConfiguredAgentsStrings strings;

  /// Called with the edited agent.
  final void Function(SavedAgentConfig agent) onSubmit;

  /// Called when the user cancels.
  final VoidCallback onCancel;

  @override
  State<AgentEditor> createState() => _AgentEditorState();
}

class _AgentEditorState extends State<AgentEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _instructions;
  late final TextEditingController _temperature;
  late final TextEditingController _maxOutputTokens;
  late String _modelId;
  late AgentAccessConfig _access;
  late List<SavedAgentConfig> _delegateCandidates;
  final Set<String> _selectedDelegates = {};
  final Map<String, TextEditingController> _delegationGuidance = {};

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _delegateCandidates = [
      for (final agent in widget.agents)
        if (agent.id != initial?.id) agent,
    ];
    final candidateIds = {for (final agent in _delegateCandidates) agent.id};
    for (final delegation
        in initial?.delegations ?? const <AgentDelegationConfig>[]) {
      if (!candidateIds.contains(delegation.agentId)) continue;
      _selectedDelegates.add(delegation.agentId);
      _delegationGuidance[delegation.agentId] = TextEditingController(
        text: delegation.instructions,
      );
    }
    _name = TextEditingController(text: initial?.name ?? '');
    _description = TextEditingController(text: initial?.description ?? '');
    _instructions = TextEditingController(text: initial?.instructions ?? '');
    _temperature = TextEditingController(
      text: initial?.temperature?.toString() ?? '',
    );
    _maxOutputTokens = TextEditingController(
      text: initial?.maxOutputTokens?.toString() ?? '',
    );
    final hasInitialModel = widget.models.any(
      (model) => model.id == initial?.modelId,
    );
    _modelId = hasInitialModel ? initial!.modelId : widget.models.first.id;
    _access = initial?.access ?? const AgentAccessConfig();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    _temperature.dispose();
    _maxOutputTokens.dispose();
    for (final controller in _delegationGuidance.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final description = _description.text.trim();
    final instructions = _instructions.text.trim();
    widget.onSubmit(
      SavedAgentConfig(
        id: widget.initial?.id ?? newConfiguredAgentsId(),
        name: _name.text.trim(),
        modelId: _modelId,
        description: description,
        instructions: instructions,
        temperature: double.tryParse(_temperature.text.trim()),
        maxOutputTokens: int.tryParse(_maxOutputTokens.text.trim()),
        access: _access,
        delegations: [
          for (final candidate in _delegateCandidates)
            if (_selectedDelegates.contains(candidate.id))
              AgentDelegationConfig(
                agentId: candidate.id,
                instructions:
                    _delegationGuidance[candidate.id]?.text.trim() ?? '',
              ),
        ],
      ),
    );
  }

  String? _validateOptionalNumber(String? value, {required bool integer}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = integer ? int.tryParse(text) : double.tryParse(text);
    return parsed == null ? widget.strings.invalidNumber : null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final style = widget.style;
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConfiguredAgentsFormField(
            label: strings.nameLabel,
            controller: _name,
            style: style,
            validator: (value) => (value == null || value.trim().isEmpty)
                ? strings.requiredField
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.modelLabel, style: style.labelTextStyle),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _modelId,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final model in widget.models)
                      DropdownMenuItem(
                        value: model.id,
                        child: Text(model.label),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _modelId = value ?? _modelId),
                ),
              ],
            ),
          ),
          ConfiguredAgentsFormField(
            label: strings.descriptionLabel,
            controller: _description,
            style: style,
          ),
          ConfiguredAgentsFormField(
            label: strings.instructionsLabel,
            controller: _instructions,
            style: style,
            maxLines: 4,
          ),
          ConfiguredAgentsFormField(
            label: strings.temperatureLabel,
            controller: _temperature,
            style: style,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (value) =>
                _validateOptionalNumber(value, integer: false),
          ),
          ConfiguredAgentsFormField(
            label: strings.maxOutputTokensLabel,
            controller: _maxOutputTokens,
            style: style,
            keyboardType: TextInputType.number,
            validator: (value) => _validateOptionalNumber(value, integer: true),
          ),
          const SizedBox(height: 8),
          if (widget.networkModelIds.contains(_modelId))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'This agent runs on another device; its tools, context, '
                'and delegations are configured on the host.',
                style: style.subtitleTextStyle,
              ),
            )
          else ...[
            _buildAccessSection(
            label: strings.agentToolsLabel,
            style: style,
            switches: [
              _AccessSwitchConfig(
                label: strings.webSearchAccessLabel,
                value: _access.enableWebSearch,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableWebSearch: value)),
              ),
              _AccessSwitchConfig(
                label: strings.temporalAccessLabel,
                value: _access.enableTemporal,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableTemporal: value)),
              ),
              _AccessSwitchConfig(
                label: strings.connectivityAccessLabel,
                value: _access.enableConnectivity,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableConnectivity: value)),
              ),
              _AccessSwitchConfig(
                label: strings.appInfoAccessLabel,
                value: _access.enableAppInfo,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableAppInfo: value)),
              ),
              _AccessSwitchConfig(
                label: strings.deviceInfoAccessLabel,
                value: _access.enableDeviceInfo,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableDeviceInfo: value)),
              ),
              _AccessSwitchConfig(
                label: strings.locationAccessLabel,
                value: _access.enableLocation,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableLocation: value)),
              ),
              _AccessSwitchConfig(
                label: strings.networkInfoAccessLabel,
                value: _access.enableNetworkInfo,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableNetworkInfo: value)),
              ),
              _AccessSwitchConfig(
                label: strings.wakeLockAccessLabel,
                value: _access.enableWakeLock,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableWakeLock: value)),
              ),
            ],
          ),
          _buildAccessSection(
            label: strings.agentContextLabel,
            style: style,
            switches: [
              _AccessSwitchConfig(
                label: strings.fileMemoryAccessLabel,
                value: _access.enableFileMemory,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableFileMemory: value)),
              ),
              _AccessSwitchConfig(
                label: strings.fileAccessLabel,
                value: _access.enableFileAccess,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableFileAccess: value)),
              ),
              _AccessSwitchConfig(
                label: strings.todoListAccessLabel,
                value: _access.enableTodoList,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableTodoList: value)),
              ),
              _AccessSwitchConfig(
                label: strings.agentModeAccessLabel,
                value: _access.enableAgentMode,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableAgentMode: value)),
              ),
              _AccessSwitchConfig(
                label: strings.skillsAccessLabel,
                value: _access.enableSkills,
                onChanged: (value) =>
                    _updateAccess(_access.copyWith(enableSkills: value)),
              ),
            ],
          ),
            if (_delegateCandidates.isNotEmpty)
              _buildDelegationSection(style, strings),
          ],
          const SizedBox(height: 12),
          EditorActions(
            style: style,
            strings: strings,
            onCancel: widget.onCancel,
            onSave: _submit,
          ),
        ],
      ),
    );
  }

  void _updateAccess(AgentAccessConfig access) {
    setState(() => _access = access);
  }

  void _toggleDelegate(String agentId, bool selected) {
    setState(() {
      if (selected) {
        _selectedDelegates.add(agentId);
        _delegationGuidance.putIfAbsent(agentId, TextEditingController.new);
      } else {
        _selectedDelegates.remove(agentId);
      }
    });
  }

  Widget _buildDelegationSection(
    ConfiguredAgentsStyle style,
    ConfiguredAgentsStrings strings,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.delegationLabel, style: style.labelTextStyle),
        const SizedBox(height: 6),
        for (final candidate in _delegateCandidates) ...[
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(candidate.name, style: style.bodyTextStyle),
            subtitle: candidate.description.isEmpty
                ? null
                : Text(candidate.description, style: style.bodyTextStyle),
            value: _selectedDelegates.contains(candidate.id),
            onChanged: (value) => _toggleDelegate(candidate.id, value),
          ),
          if (_selectedDelegates.contains(candidate.id))
            ConfiguredAgentsFormField(
              label: strings.delegationGuidanceLabel,
              controller: _delegationGuidance[candidate.id]!,
              style: style,
              hintText: strings.delegationGuidanceHint,
            ),
        ],
      ],
    ),
  );

  Widget _buildAccessSection({
    required String label,
    required ConfiguredAgentsStyle style,
    required List<_AccessSwitchConfig> switches,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: style.labelTextStyle),
        const SizedBox(height: 6),
        for (final accessSwitch in switches)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(accessSwitch.label, style: style.bodyTextStyle),
            value: accessSwitch.value,
            onChanged: accessSwitch.onChanged,
          ),
      ],
    ),
  );
}

class _AccessSwitchConfig {
  const _AccessSwitchConfig({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
}

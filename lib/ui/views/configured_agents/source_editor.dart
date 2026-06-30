// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';
import 'configured_agents_form_field.dart';
import 'editor_actions.dart';

/// Editor form for creating or updating a [ModelSourceConfig].
///
/// The API key is handled separately from the config: when [hasStoredKey] is
/// true the field is optional and an empty value keeps the existing key.
class SourceEditor extends StatefulWidget {
  /// Creates a [SourceEditor].
  const SourceEditor({
    required this.style,
    required this.strings,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.hasStoredKey = false,
    super.key,
  });

  /// The source being edited, or `null` to create a new one.
  final ModelSourceConfig? initial;

  /// Whether an API key is already stored for the source.
  final bool hasStoredKey;

  /// Resolved style.
  final ConfiguredAgentsStyle style;

  /// Resolved strings.
  final ConfiguredAgentsStrings strings;

  /// Called with the edited source and the entered API key (or `null` when the
  /// field was left blank).
  final void Function(ModelSourceConfig source, String? apiKey) onSubmit;

  /// Called when the user cancels.
  final VoidCallback onCancel;

  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<SourceEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayName;
  late final TextEditingController _endpoint;
  late final TextEditingController _apiKey;
  late ProviderType _provider;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _displayName = TextEditingController(text: initial?.displayName ?? '');
    _endpoint = TextEditingController(text: initial?.endpoint ?? '');
    _apiKey = TextEditingController();
    _provider = initial?.providerType ?? ProviderType.openAiCompatible;
  }

  @override
  void dispose() {
    _displayName.dispose();
    _endpoint.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final endpoint = _endpoint.text.trim();
    final source = ModelSourceConfig(
      id: widget.initial?.id ?? newConfiguredAgentsId(),
      providerType: _provider,
      displayName: _displayName.text.trim(),
      endpoint: _provider == ProviderType.localLlama || endpoint.isEmpty
          ? null
          : endpoint,
      settings: widget.initial?.settings ?? const {},
    );
    final key = _apiKey.text;
    widget.onSubmit(source, key.isEmpty ? null : key);
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.providerLabel, style: style.labelTextStyle),
                const SizedBox(height: 6),
                DropdownButtonFormField<ProviderType>(
                  initialValue: _provider,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    DropdownMenuItem(
                      value: ProviderType.openAiCompatible,
                      child: Text(strings.openAiCompatibleProvider),
                    ),
                    DropdownMenuItem(
                      value: ProviderType.anthropic,
                      child: Text(strings.anthropicProvider),
                    ),
                    const DropdownMenuItem(
                      value: ProviderType.localLlama,
                      child: Text('Local llama'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _provider = value ?? _provider),
                ),
              ],
            ),
          ),
          ConfiguredAgentsFormField(
            label: strings.displayNameLabel,
            controller: _displayName,
            style: style,
            validator: (value) => (value == null || value.trim().isEmpty)
                ? strings.requiredField
                : null,
          ),
          if (_provider != ProviderType.localLlama) ...[
            ConfiguredAgentsFormField(
              label: strings.endpointLabel,
              controller: _endpoint,
              style: style,
              keyboardType: TextInputType.url,
              hintText: 'https://api.openai.com/v1',
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return null;
                final uri = Uri.tryParse(text);
                return (uri == null || !uri.isAbsolute)
                    ? strings.invalidEndpoint
                    : null;
              },
            ),
            ConfiguredAgentsFormField(
              label: strings.apiKeyLabel,
              controller: _apiKey,
              style: style,
              obscureText: true,
              hintText: widget.hasStoredKey ? strings.apiKeyStoredHint : null,
              validator: (value) {
                if (widget.hasStoredKey || !_provider.requiresApiKey) {
                  return null;
                }
                return (value == null || value.isEmpty)
                    ? strings.requiredField
                    : null;
              },
            ),
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
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';
import 'configured_agents_form_field.dart';
import 'editor_actions.dart';

/// A selected local GGUF model file.
@immutable
class LlamaModelFileSelection {
  /// Creates a [LlamaModelFileSelection].
  const LlamaModelFileSelection({required this.path, required this.name});

  /// The platform path or browser object URL for the selected file.
  final String path;

  /// The display name of the selected file.
  final String name;
}

/// Opens a GGUF model file picker.
typedef LlamaModelFilePicker = Future<LlamaModelFileSelection?> Function();

final Map<String, String> _selectedLlamaModelFilePaths = {};

/// Registers a runtime-only local llama file selection.
void registerSelectedLlamaModelFile(String modelId, String path) {
  _selectedLlamaModelFilePaths[modelId] = path;
}

/// Returns the runtime-only selected file path for [modelId], if any.
String? selectedLlamaModelFilePathFor(String modelId) =>
    _selectedLlamaModelFilePaths[modelId];

/// Clears any runtime-only selected file path for [modelId].
void clearSelectedLlamaModelFile(String modelId) {
  _selectedLlamaModelFilePaths.remove(modelId);
}

/// Opens the default platform file picker for GGUF model files.
Future<LlamaModelFileSelection?> pickDefaultLlamaModelFile() async {
  final file = await file_selector.openFile(
    acceptedTypeGroups: const [
      file_selector.XTypeGroup(label: 'GGUF model', extensions: ['gguf']),
    ],
    confirmButtonText: 'Choose',
  );
  if (file == null) return null;
  final name = file.name.isEmpty ? _filenameFromPath(file.path) : file.name;
  return LlamaModelFileSelection(path: file.path, name: name);
}

String _filenameFromPath(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}

enum _LlamaModelSource { url, file }

/// Editor form for creating or updating a [ModelConfig].
class ModelEditor extends StatefulWidget {
  /// Creates a [ModelEditor].
  const ModelEditor({
    required this.sources,
    required this.style,
    required this.strings,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.pickLlamaModelFile = pickDefaultLlamaModelFile,
    super.key,
  });

  /// The model being edited, or `null` to create a new one.
  final ModelConfig? initial;

  /// Sources the model may belong to. Must be non-empty.
  final List<ModelSourceConfig> sources;

  /// Resolved style.
  final ConfiguredAgentsStyle style;

  /// Resolved strings.
  final ConfiguredAgentsStrings strings;

  /// Called with the edited model.
  final void Function(ModelConfig model) onSubmit;

  /// Called when the user cancels.
  final VoidCallback onCancel;

  /// Selects a local GGUF model file for local llama models.
  final LlamaModelFilePicker pickLlamaModelFile;

  @override
  State<ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<ModelEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelId;
  late final TextEditingController _displayName;
  late final TextEditingController _llamaModelUrl;
  late final TextEditingController _llamaContextSize;
  late final TextEditingController _llamaGpuLayers;
  late final TextEditingController _llamaFormat;
  late String _sourceId;
  late _LlamaModelSource _llamaModelSource;
  String? _llamaModelPath;
  String? _llamaModelFileName;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _modelId = TextEditingController(text: initial?.modelId ?? '');
    _displayName = TextEditingController(text: initial?.displayName ?? '');
    _llamaModelUrl = TextEditingController(
      text: initial?.settings['llama.modelUrl'] ?? '',
    );
    _llamaContextSize = TextEditingController(
      text: initial?.settings['llama.contextSize'] ?? '4096',
    );
    _llamaGpuLayers = TextEditingController(
      text: initial?.settings['llama.gpuLayers'] ?? '999',
    );
    _llamaFormat = TextEditingController(
      text: initial?.settings['llama.format'] ?? 'gemma',
    );
    _sourceId = initial?.sourceId ?? widget.sources.first.id;
    final settings = initial?.settings ?? const <String, String>{};
    _llamaModelSource =
        settings['llama.modelSource'] == 'file' ||
            settings.containsKey('llama.modelPath')
        ? _LlamaModelSource.file
        : _LlamaModelSource.url;
    _llamaModelPath = kIsWeb ? null : settings['llama.modelPath'];
    _llamaModelFileName = settings['llama.modelFileName'];
  }

  @override
  void dispose() {
    _modelId.dispose();
    _displayName.dispose();
    _llamaModelUrl.dispose();
    _llamaContextSize.dispose();
    _llamaGpuLayers.dispose();
    _llamaFormat.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final displayName = _displayName.text.trim();
    final isLocal = _selectedSource.providerType == ProviderType.localLlama;
    final id = widget.initial?.id ?? newConfiguredAgentsId();
    final settings = isLocal
        ? _localLlamaSettings(id)
        : widget.initial?.settings ?? const <String, String>{};
    widget.onSubmit(
      ModelConfig(
        id: id,
        sourceId: _sourceId,
        modelId: isLocal ? widget.initial?.modelId ?? id : _modelId.text.trim(),
        displayName: displayName.isEmpty ? null : displayName,
        settings: settings,
      ),
    );
  }

  Map<String, String> _localLlamaSettings(String id) {
    final settings = <String, String>{
      'llama.modelSource': switch (_llamaModelSource) {
        _LlamaModelSource.url => 'url',
        _LlamaModelSource.file => 'file',
      },
      'llama.contextSize': _llamaContextSize.text.trim(),
      'llama.gpuLayers': _llamaGpuLayers.text.trim(),
      'llama.format': _llamaFormat.text.trim().isEmpty
          ? 'gemma'
          : _llamaFormat.text.trim(),
    };

    switch (_llamaModelSource) {
      case _LlamaModelSource.url:
        clearSelectedLlamaModelFile(id);
        settings['llama.modelUrl'] = _llamaModelUrl.text.trim();
      case _LlamaModelSource.file:
        final path = _llamaModelPath?.trim();
        if (path != null && path.isNotEmpty) {
          registerSelectedLlamaModelFile(id, path);
          if (!kIsWeb) settings['llama.modelPath'] = path;
        }
        final fileName = _llamaModelFileName?.trim();
        if (fileName != null && fileName.isNotEmpty) {
          settings['llama.modelFileName'] = fileName;
        }
    }
    return settings;
  }

  Future<String?> _chooseLlamaModelFile() async {
    final selection = await widget.pickLlamaModelFile();
    if (selection == null) return null;
    setState(() {
      _llamaModelPath = selection.path;
      _llamaModelFileName = selection.name;
    });
    return selection.path;
  }

  ModelSourceConfig get _selectedSource => widget.sources.firstWhere(
    (source) => source.id == _sourceId,
    orElse: () => widget.sources.first,
  );

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
                Text(strings.sourceLabel, style: style.labelTextStyle),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _sourceId,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final source in widget.sources)
                      DropdownMenuItem(
                        value: source.id,
                        child: Text(source.displayName),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() => _sourceId = value ?? _sourceId);
                  },
                ),
              ],
            ),
          ),
          if (_selectedSource.providerType == ProviderType.localLlama) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Model source', style: style.labelTextStyle),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<_LlamaModelSource>(
                    initialValue: _llamaModelSource,
                    decoration: const InputDecoration(isDense: true),
                    items: const [
                      DropdownMenuItem(
                        value: _LlamaModelSource.url,
                        child: Text('URL'),
                      ),
                      DropdownMenuItem(
                        value: _LlamaModelSource.file,
                        child: Text('File'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _llamaModelSource = value ?? _llamaModelSource;
                      });
                    },
                  ),
                ],
              ),
            ),
            if (_llamaModelSource == _LlamaModelSource.url)
              ConfiguredAgentsFormField(
                label: 'GGUF model URL',
                controller: _llamaModelUrl,
                style: style,
                keyboardType: TextInputType.url,
                hintText:
                    'https://huggingface.co/org/repo/resolve/main/model-00001-of-00002.gguf',
                validator: (value) {
                  final text = value?.trim() ?? '';
                  final uri = Uri.tryParse(text);
                  return text.isEmpty || uri == null || !uri.isAbsolute
                      ? strings.invalidEndpoint
                      : null;
                },
              )
            else
              _LlamaModelFileField(
                fileName: _llamaModelFileName,
                path: _llamaModelPath,
                style: style,
                onChoose: _chooseLlamaModelFile,
              ),
            ConfiguredAgentsFormField(
              label: 'Context size',
              controller: _llamaContextSize,
              style: style,
              keyboardType: TextInputType.number,
              validator: (value) => int.tryParse(value?.trim() ?? '') == null
                  ? strings.invalidNumber
                  : null,
            ),
            ConfiguredAgentsFormField(
              label: 'GPU layers',
              controller: _llamaGpuLayers,
              style: style,
              keyboardType: TextInputType.number,
              validator: (value) => int.tryParse(value?.trim() ?? '') == null
                  ? strings.invalidNumber
                  : null,
            ),
            ConfiguredAgentsFormField(
              label: 'Format',
              controller: _llamaFormat,
              style: style,
              hintText: 'gemma',
              validator: (value) {
                final text = (value ?? '').trim();
                const supported = {'', 'gemma', 'lfm2', 'lfm2-vl'};
                return supported.contains(text)
                    ? null
                    : 'Supported formats: gemma, lfm2, lfm2-vl.';
              },
            ),
          ] else
            ConfiguredAgentsFormField(
              label: strings.modelIdLabel,
              controller: _modelId,
              style: style,
              hintText: 'gpt-4o',
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? strings.requiredField
                  : null,
            ),
          ConfiguredAgentsFormField(
            label: strings.modelDisplayNameLabel,
            controller: _displayName,
            style: style,
          ),
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

class _LlamaModelFileField extends StatelessWidget {
  const _LlamaModelFileField({
    required this.fileName,
    required this.path,
    required this.style,
    required this.onChoose,
  });

  final String? fileName;
  final String? path;
  final ConfiguredAgentsStyle style;
  final Future<String?> Function() onChoose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: FormField<String>(
      initialValue: path,
      validator: (_) {
        final selectedPath = path?.trim();
        return selectedPath == null || selectedPath.isEmpty
            ? 'Choose a GGUF model file.'
            : null;
      },
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GGUF model file', style: style.labelTextStyle),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.bodyTextStyle,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final selectedPath = await onChoose();
                  if (selectedPath != null) field.didChange(selectedPath);
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose file'),
              ),
            ],
          ),
          if (field.hasError) ...[
            const SizedBox(height: 6),
            Text(field.errorText!, style: style.errorTextStyle),
          ],
        ],
      ),
    ),
  );

  String get _label {
    final selectedName = fileName?.trim();
    if (selectedName != null && selectedName.isNotEmpty) return selectedName;
    final selectedPath = path?.trim();
    return selectedPath == null || selectedPath.isEmpty
        ? 'No file selected'
        : _filenameFromPath(selectedPath);
  }
}

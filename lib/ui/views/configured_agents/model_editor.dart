// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents_llama/agents_llama.dart' as llama;
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

/// The role a locally selected GGUF file plays for a local llama model.
enum LlamaArtifactKind {
  /// The main model weights.
  model,

  /// The optional multimodal projector (mmproj) enabling image input.
  mmproj,

  /// The optional speculative-decoding draft/MTP model.
  draft,
}

final Map<String, Map<LlamaArtifactKind, String>> _selectedLlamaModelFilePaths =
    {};

/// Registers a runtime-only local llama file selection for [kind].
void registerSelectedLlamaModelFile(
  String modelId,
  String path, {
  LlamaArtifactKind kind = LlamaArtifactKind.model,
}) {
  (_selectedLlamaModelFilePaths[modelId] ??= {})[kind] = path;
}

/// Returns the runtime-only selected file path of [kind] for [modelId].
String? selectedLlamaModelFilePathFor(
  String modelId, {
  LlamaArtifactKind kind = LlamaArtifactKind.model,
}) => _selectedLlamaModelFilePaths[modelId]?[kind];

/// Clears runtime-only selected file paths for [modelId]: the one for
/// [kind], or every artifact when [kind] is null.
void clearSelectedLlamaModelFile(String modelId, {LlamaArtifactKind? kind}) {
  if (kind == null) {
    _selectedLlamaModelFilePaths.remove(modelId);
    return;
  }
  final paths = _selectedLlamaModelFilePaths[modelId];
  paths?.remove(kind);
  if (paths != null && paths.isEmpty) {
    _selectedLlamaModelFilePaths.remove(modelId);
  }
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
  late final TextEditingController _llamaMmprojUrl;
  late final TextEditingController _llamaDraftUrl;
  late final TextEditingController _llamaContextSize;
  late final TextEditingController _llamaGpuLayers;
  late String _sourceId;
  late _LlamaModelSource _llamaModelSource;
  String? _llamaModelPath;
  String? _llamaModelFileName;
  String? _llamaMmprojPath;
  String? _llamaMmprojFileName;
  String? _llamaDraftPath;
  String? _llamaDraftFileName;

  /// Selected chat format; empty means auto-detect at runtime.
  late String _chatFormat;

  /// Selected tools mode setting value; empty means auto (native).
  late String _toolsMode;
  late bool _toolsParallel;

  /// Selected reasoning-tags setting value; empty means auto-detect.
  late String _reasoningTags;

  /// What name-based (or GGUF) detection currently suggests, for the
  /// "Auto" helper text.
  String? _detectedFormat;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _modelId = TextEditingController(text: initial?.modelId ?? '');
    _displayName = TextEditingController(text: initial?.displayName ?? '');
    _llamaModelUrl = TextEditingController(
      text: initial?.settings['llama.modelUrl'] ?? '',
    );
    _llamaMmprojUrl = TextEditingController(
      text: initial?.settings['llama.mmprojUrl'] ?? '',
    );
    _llamaDraftUrl = TextEditingController(
      text: initial?.settings['llama.draftModelUrl'] ?? '',
    );
    _llamaContextSize = TextEditingController(
      text: initial?.settings['llama.contextSize'] ?? '4096',
    );
    _llamaGpuLayers = TextEditingController(
      text: initial?.settings['llama.gpuLayers'] ?? '999',
    );
    _sourceId = initial?.sourceId ?? widget.sources.first.id;
    final settings = initial?.settings ?? const <String, String>{};
    _chatFormat = _knownFormatOrAuto(
      settings[chatFormatSetting] ?? settings[legacyLlamaFormatSetting],
    );
    _toolsMode = switch (settings[toolsModeSetting]) {
      toolsModeNative || toolsModePrompt || toolsModeNone => //
      settings[toolsModeSetting]!,
      _ => '',
    };
    _toolsParallel = settings[toolsParallelSetting] != 'false';
    _reasoningTags = switch (settings[reasoningTagsSetting]) {
      reasoningTagsThink || reasoningTagsNone => //
      settings[reasoningTagsSetting]!,
      _ => '',
    };
    _llamaModelSource =
        settings['llama.modelSource'] == 'file' ||
            settings.containsKey('llama.modelPath')
        ? _LlamaModelSource.file
        : _LlamaModelSource.url;
    _llamaModelPath = kIsWeb ? null : settings['llama.modelPath'];
    _llamaModelFileName = settings['llama.modelFileName'];
    _llamaMmprojPath = kIsWeb ? null : settings['llama.mmprojPath'];
    _llamaMmprojFileName = settings['llama.mmprojFileName'];
    _llamaDraftPath = kIsWeb ? null : settings['llama.draftModelPath'];
    _llamaDraftFileName = settings['llama.draftModelFileName'];
    _modelId.addListener(_refreshDetection);
    _llamaModelUrl.addListener(_refreshDetection);
    _refreshDetection();
  }

  /// Normalizes a stored format name: unknown or empty becomes auto ('').
  static String _knownFormatOrAuto(String? name) {
    final trimmed = name?.trim() ?? '';
    return llama.supportedChatFormatNames.contains(trimmed) ? trimmed : '';
  }

  /// Re-runs name-based detection for the helper text.
  void _refreshDetection() {
    final basis = switch (_selectedSource.providerType) {
      ProviderType.localLlama =>
        _llamaModelSource == _LlamaModelSource.file
            ? (_llamaModelFileName ?? '')
            : _llamaModelUrl.text,
      _ => _modelId.text,
    };
    final detected = basis.trim().isEmpty ? null : detectChatFormatName(basis);
    if (detected != _detectedFormat) {
      setState(() => _detectedFormat = detected);
    }
  }

  /// Sniffs a picked GGUF file's metadata for a higher-confidence
  /// detection than the file name; no-op on the web.
  Future<void> _sniffGgufFormat(String path) async {
    final metadata = await readGgufMetadata(path);
    if (metadata == null || !mounted) return;
    final detected = chatFormatFromGgufMetadata(metadata);
    if (detected != null && detected != _detectedFormat) {
      setState(() => _detectedFormat = detected);
    }
  }

  @override
  void dispose() {
    _modelId.dispose();
    _displayName.dispose();
    _llamaModelUrl.dispose();
    _llamaMmprojUrl.dispose();
    _llamaDraftUrl.dispose();
    _llamaContextSize.dispose();
    _llamaGpuLayers.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final displayName = _displayName.text.trim();
    final isLocal = _selectedSource.providerType == ProviderType.localLlama;
    final id = widget.initial?.id ?? newConfiguredAgentsId();
    final settings = switch (_selectedSource.providerType) {
      ProviderType.localLlama => _localLlamaSettings(id),
      ProviderType.openAiCompatible => _openAiCompatibleSettings(),
      _ => widget.initial?.settings ?? const <String, String>{},
    };
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

  /// Builds the `chat.*`/`tools.*` settings for an OpenAI-compatible
  /// model, preserving any unrelated settings already stored.
  Map<String, String> _openAiCompatibleSettings() {
    final settings = Map<String, String>.of(
      widget.initial?.settings ?? const <String, String>{},
    );

    void put(String key, String value) {
      if (value.isEmpty) {
        settings.remove(key);
      } else {
        settings[key] = value;
      }
    }

    put(chatFormatSetting, _chatFormat);
    put(toolsModeSetting, _toolsMode);
    put(toolsParallelSetting, _toolsParallel ? '' : 'false');
    put(reasoningTagsSetting, _reasoningTags);
    return settings;
  }

  Map<String, String> _localLlamaSettings(String id) {
    final settings = <String, String>{
      'llama.modelSource': switch (_llamaModelSource) {
        _LlamaModelSource.url => 'url',
        _LlamaModelSource.file => 'file',
      },
      'llama.contextSize': _llamaContextSize.text.trim(),
      'llama.gpuLayers': _llamaGpuLayers.text.trim(),
      // Both keys are written: chat.format is canonical, llama.format
      // keeps older readers working. Empty means auto-detect.
      if (_chatFormat.isNotEmpty) ...{
        chatFormatSetting: _chatFormat,
        legacyLlamaFormatSetting: _chatFormat,
      },
    };

    switch (_llamaModelSource) {
      case _LlamaModelSource.url:
        clearSelectedLlamaModelFile(id);
        settings['llama.modelUrl'] = _llamaModelUrl.text.trim();
        final mmprojUrl = _llamaMmprojUrl.text.trim();
        if (mmprojUrl.isNotEmpty) settings['llama.mmprojUrl'] = mmprojUrl;
        final draftUrl = _llamaDraftUrl.text.trim();
        if (draftUrl.isNotEmpty) settings['llama.draftModelUrl'] = draftUrl;
      case _LlamaModelSource.file:
        // The main-model registration is kind `model`; an empty selection is
        // left registered so a web reload does not lose it mid-session. The
        // optional artifacts additionally clear their registration when the
        // user removed the selection (empty file name).
        void applyFileArtifact({
          required LlamaArtifactKind kind,
          required String? path,
          required String? fileName,
          required String pathKey,
          required String fileNameKey,
        }) {
          final selectedPath = path?.trim();
          if (selectedPath != null && selectedPath.isNotEmpty) {
            registerSelectedLlamaModelFile(id, selectedPath, kind: kind);
            if (!kIsWeb) settings[pathKey] = selectedPath;
          }
          final selectedName = fileName?.trim();
          if (selectedName != null && selectedName.isNotEmpty) {
            settings[fileNameKey] = selectedName;
          } else if (kind != LlamaArtifactKind.model) {
            clearSelectedLlamaModelFile(id, kind: kind);
          }
        }

        applyFileArtifact(
          kind: LlamaArtifactKind.model,
          path: _llamaModelPath,
          fileName: _llamaModelFileName,
          pathKey: 'llama.modelPath',
          fileNameKey: 'llama.modelFileName',
        );
        applyFileArtifact(
          kind: LlamaArtifactKind.mmproj,
          path: _llamaMmprojPath,
          fileName: _llamaMmprojFileName,
          pathKey: 'llama.mmprojPath',
          fileNameKey: 'llama.mmprojFileName',
        );
        applyFileArtifact(
          kind: LlamaArtifactKind.draft,
          path: _llamaDraftPath,
          fileName: _llamaDraftFileName,
          pathKey: 'llama.draftModelPath',
          fileNameKey: 'llama.draftModelFileName',
        );
    }
    return settings;
  }

  Future<String?> _chooseLlamaFile(
    void Function(LlamaModelFileSelection selection) apply,
  ) async {
    final selection = await widget.pickLlamaModelFile();
    if (selection == null) return null;
    setState(() => apply(selection));
    return selection.path;
  }

  Future<String?> _chooseLlamaModelFile() async {
    final path = await _chooseLlamaFile((selection) {
      _llamaModelPath = selection.path;
      _llamaModelFileName = selection.name;
    });
    if (path != null) {
      _refreshDetection();
      unawaited(_sniffGgufFormat(path));
    }
    return path;
  }

  Future<String?> _chooseLlamaMmprojFile() => _chooseLlamaFile((selection) {
    _llamaMmprojPath = selection.path;
    _llamaMmprojFileName = selection.name;
  });

  Future<String?> _chooseLlamaDraftFile() => _chooseLlamaFile((selection) {
    _llamaDraftPath = selection.path;
    _llamaDraftFileName = selection.name;
  });

  void _clearLlamaMmprojFile() => setState(() {
    _llamaMmprojPath = null;
    _llamaMmprojFileName = null;
  });

  void _clearLlamaDraftFile() => setState(() {
    _llamaDraftPath = null;
    _llamaDraftFileName = null;
  });

  static String? _optionalUrlError(
    String? value,
    ConfiguredAgentsStrings strings,
  ) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri == null || !uri.isAbsolute ? strings.invalidEndpoint : null;
  }

  ModelSourceConfig get _selectedSource => widget.sources.firstWhere(
    (source) => source.id == _sourceId,
    orElse: () => widget.sources.first,
  );

  /// The chat-format dropdown: Auto (with the detected name as helper
  /// text) plus every supported format name.
  Widget _formatDropdown(ConfiguredAgentsStyle style) {
    final names = llama.supportedChatFormatNames.toList()..sort();
    final autoLabel = _detectedFormat == null
        ? 'Auto'
        : 'Auto (detected: $_detectedFormat)';
    return _labeledDropdown<String>(
      label: 'Format',
      style: style,
      value: _chatFormat,
      items: [('', autoLabel), for (final name in names) (name, name)],
      onChanged: (value) => setState(() => _chatFormat = value),
    );
  }

  /// A labeled dropdown following the source-selector layout above.
  Widget _labeledDropdown<T>({
    required String label,
    required ConfiguredAgentsStyle style,
    required T value,
    required List<(T, String)> items,
    required ValueChanged<T> onChanged,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: style.labelTextStyle),
        const SizedBox(height: 6),
        DropdownButtonFormField<T>(
          initialValue: value,
          decoration: const InputDecoration(isDense: true),
          items: [
            for (final (itemValue, itemLabel) in items)
              DropdownMenuItem(value: itemValue, child: Text(itemLabel)),
          ],
          onChanged: (selected) {
            if (selected != null) onChanged(selected);
          },
        ),
      ],
    ),
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
            if (_llamaModelSource == _LlamaModelSource.url) ...[
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
              ),
              ConfiguredAgentsFormField(
                label: 'Projector (mmproj) GGUF URL (optional)',
                controller: _llamaMmprojUrl,
                style: style,
                keyboardType: TextInputType.url,
                validator: (value) => _optionalUrlError(value, strings),
              ),
              ConfiguredAgentsFormField(
                label: 'Draft/MTP GGUF URL (optional)',
                controller: _llamaDraftUrl,
                style: style,
                keyboardType: TextInputType.url,
                validator: (value) => _optionalUrlError(value, strings),
              ),
            ] else ...[
              _LlamaModelFileField(
                fileName: _llamaModelFileName,
                path: _llamaModelPath,
                style: style,
                onChoose: _chooseLlamaModelFile,
              ),
              _LlamaModelFileField(
                label: 'Projector (mmproj) GGUF file (optional)',
                fileName: _llamaMmprojFileName,
                path: _llamaMmprojPath,
                style: style,
                onChoose: _chooseLlamaMmprojFile,
                onClear: _clearLlamaMmprojFile,
              ),
              _LlamaModelFileField(
                label: 'Draft/MTP GGUF file (optional)',
                fileName: _llamaDraftFileName,
                path: _llamaDraftPath,
                style: style,
                onChoose: _chooseLlamaDraftFile,
                onClear: _clearLlamaDraftFile,
              ),
            ],
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
            _formatDropdown(style),
          ] else ...[
            ConfiguredAgentsFormField(
              label: strings.modelIdLabel,
              controller: _modelId,
              style: style,
              hintText: 'gpt-4o',
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? strings.requiredField
                  : null,
            ),
            if (_selectedSource.providerType ==
                ProviderType.openAiCompatible) ...[
              _formatDropdown(style),
              _labeledDropdown<String>(
                label: 'Tool calling',
                style: style,
                value: _toolsMode,
                items: const [
                  ('', 'Native (default)'),
                  (toolsModePrompt, 'Prompt-injected'),
                  (toolsModeNone, 'Disabled'),
                ],
                onChanged: (value) => setState(() => _toolsMode = value),
              ),
              _labeledDropdown<String>(
                label: 'Reasoning tags',
                style: style,
                value: _reasoningTags,
                items: const [
                  ('', 'Auto'),
                  (reasoningTagsThink, '<think> tags'),
                  (reasoningTagsNone, 'None'),
                ],
                onChanged: (value) => setState(() => _reasoningTags = value),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Parallel tool calls',
                        style: style.labelTextStyle,
                      ),
                    ),
                    Switch(
                      value: _toolsParallel,
                      onChanged: (value) {
                        setState(() => _toolsParallel = value);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ],
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
    this.label = 'GGUF model file',
    this.onClear,
  });

  final String? fileName;
  final String? path;
  final ConfiguredAgentsStyle style;
  final Future<String?> Function() onChoose;

  /// The field label above the file row.
  final String label;

  /// Removes the selection. Non-null marks the field optional: no required
  /// validator, and a clear button next to a selected file.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: FormField<String>(
      initialValue: path,
      validator: (_) {
        if (onClear != null) return null;
        final selectedPath = path?.trim();
        return selectedPath == null || selectedPath.isEmpty
            ? 'Choose a GGUF model file.'
            : null;
      },
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: style.labelTextStyle),
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
              if (onClear != null && _hasSelection)
                IconButton(
                  onPressed: () {
                    onClear!();
                    field.didChange(null);
                  },
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear selection',
                ),
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

  bool get _hasSelection =>
      (fileName?.trim().isNotEmpty ?? false) ||
      (path?.trim().isNotEmpty ?? false);

  String get _label {
    final selectedName = fileName?.trim();
    if (selectedName != null && selectedName.isNotEmpty) return selectedName;
    final selectedPath = path?.trim();
    return selectedPath == null || selectedPath.isEmpty
        ? 'No file selected'
        : _filenameFromPath(selectedPath);
  }
}

// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/local_models/local_model_disk.dart';
import '../widgets/settings_page.dart';

/// Formats [bytes] the way storage UIs do: one decimal, sensible unit.
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

/// One local model and what its files occupy.
typedef _ModelUsage = ({ModelConfig model, bool pickedFile, int? bytes});

/// The Storage sub-page: where local-model files live, what each model
/// occupies, and per-model reclamation.
///
/// Deleting here frees a model's bytes without touching its configuration —
/// the difference from deleting the model in the Agent Center. A URL-backed
/// model downloads again the next time it runs; a picked-file model needs
/// its file picked again.
class StorageSettingsScreen extends StatefulWidget {
  /// Creates a [StorageSettingsScreen].
  const StorageSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends State<StorageSettingsScreen> {
  late final ConfiguredAgentsManager _manager;
  StreamSubscription<void>? _changes;

  String? _rootPath;
  List<_ModelUsage>? _usages;

  @override
  void initState() {
    super.initState();
    _manager = widget.services.getRequiredService<ConfiguredAgentsManager>();
    _changes = _manager.configurationChanges.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Loads the local models and measures each one's stores.
  Future<void> _load() async {
    final rootPath = await localModelStorageRootPath();
    final models = await _manager.sources.listModels();
    final sources = await _manager.sources.listSources();
    final localSourceIds = {
      for (final source in sources)
        if (source.providerType == ProviderType.localLlama) source.id,
    };
    final usages = <_ModelUsage>[
      for (final model in models)
        if (localSourceIds.contains(model.sourceId))
          (
            model: model,
            pickedFile: model.settings['llama.modelSource'] == 'file',
            bytes: await localModelDiskUsage(model),
          ),
    ];
    if (!mounted) return;
    setState(() {
      _rootPath = rootPath;
      _usages = usages;
    });
  }

  Future<void> _confirmAndDelete(_ModelUsage usage) async {
    final label = usage.model.label;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete the files for "$label"?'),
        content: Text(
          usage.pickedFile
              ? 'The stored copy is deleted; the model stays configured. '
                    'You will need to pick its file again before it can run.'
              : 'The downloaded files are deleted; the model stays '
                    'configured and downloads them again the next time it '
                    'runs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete files'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await deleteLocalModelBytes(usage.model);
    await _load();
  }

  Future<void> _openRootFolder(String path) async {
    final opened = await launchUrl(Uri.directory(path));
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open the folder')));
  }

  @override
  Widget build(BuildContext context) {
    final usages = _usages;
    return SettingsPage(
      title: 'Storage',
      children: [
        const SettingsGroupCaption(
          'Local models keep their files on this device — the ones you '
          'picked and the ones the runtime downloaded. Deleting files here '
          'frees the space and keeps the model configured.',
        ),
        if (_rootPath case final path?)
          ListTile(
            leading: const Icon(LucideIcons.folder300),
            title: const Text('Models folder'),
            subtitle: Text(path),
            trailing: const Icon(LucideIcons.folderOpen300),
            onTap: () => unawaited(_openRootFolder(path)),
          ),
        const SettingsGroupLabel('Local models'),
        if (usages == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (usages.isEmpty) ...[
          const SettingsGroupCaption(
            'No local models are configured, so nothing is stored. Models '
            'run through an API leave no files here.',
          ),
          ListTile(
            leading: const Icon(LucideIcons.boxes300),
            title: const Text('Open models'),
            trailing: const Icon(LucideIcons.chevronRight300),
            onTap: () => context.go('/settings/agents/models'),
          ),
        ] else ...[
          for (final usage in usages)
            _ModelUsageTile(
              usage: usage,
              onDelete: () => unawaited(_confirmAndDelete(usage)),
            ),
          if (usages.any((usage) => usage.bytes != null))
            ListTile(
              title: const Text('Total'),
              trailing: Text(
                formatBytes(
                  [
                    for (final usage in usages) usage.bytes ?? 0,
                  ].fold(0, (sum, bytes) => sum + bytes),
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// One local model's row: what it occupies, and the delete that frees it.
class _ModelUsageTile extends StatelessWidget {
  const _ModelUsageTile({required this.usage, required this.onDelete});

  final _ModelUsage usage;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = usage.bytes;
    final subtitle = switch (bytes) {
      null => usage.pickedFile ? 'Picked file · size unknown' : 'Size unknown',
      0 =>
        usage.pickedFile
            ? 'No stored copy — pick its file to run it'
            : 'Nothing downloaded yet',
      _ =>
        usage.pickedFile
            ? '${formatBytes(bytes)} · picked file'
            : '${formatBytes(bytes)} · downloaded',
    };
    final deletable = bytes == null || bytes > 0;
    return ListTile(
      leading: const Icon(LucideIcons.cpu300),
      title: Text(usage.model.label),
      subtitle: Text(subtitle),
      trailing: deletable
          ? IconButton(
              tooltip: 'Delete files',
              icon: Icon(LucideIcons.trash2300, color: scheme.error),
              onPressed: onDelete,
            )
          : null,
    );
  }
}

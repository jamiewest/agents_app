// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/prompt_log.dart';
import '../widgets/prompt_inspector_panel.dart';

/// Live in-app logs with runtime level controls.
///
/// The Events tab shows every captured log record with display filters
/// (level, category, text search) plus the capture controls that decide what
/// gets recorded in the first place: the global minimum level and
/// per-category overrides from [LoggingSettings]. The Prompts tab embeds the
/// existing prompt inspector so raw model requests live alongside the event
/// log.
class LoggingScreen extends StatelessWidget {
  /// Creates a [LoggingScreen].
  const LoggingScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final store = services.getService<AppLogStore>();
    final settings = services.getService<LoggingSettings>();
    final promptLog = services.getService<PromptLog>();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Logs & diagnostics'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Events'),
              Tab(text: 'Prompts'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            if (store == null || settings == null)
              const _Unavailable(
                'In-app logging is not registered for this build.',
              )
            else
              _EventsTab(store: store, settings: settings),
            if (promptLog == null)
              const _Unavailable('Prompt capture is not registered.')
            else
              PromptInspectorPanel(log: promptLog),
          ],
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(24), child: Text(message)),
  );
}

/// The levels a user can pick from; `none` appears only as the per-category
/// "Off" override.
const List<LogLevel> _pickableLevels = [
  LogLevel.trace,
  LogLevel.debug,
  LogLevel.information,
  LogLevel.warning,
  LogLevel.error,
  LogLevel.critical,
];

/// Short display label for [level].
///
/// The extensions package shadows `EnumName.name` with a `LogLevel.Trace`
/// style getter, so labels are spelled out here.
String _levelLabel(LogLevel level) => switch (level) {
  LogLevel.trace => 'Trace',
  LogLevel.debug => 'Debug',
  LogLevel.information => 'Info',
  LogLevel.warning => 'Warn',
  LogLevel.error => 'Error',
  LogLevel.critical => 'Critical',
  LogLevel.none => 'Off',
};

Color _levelColor(BuildContext context, LogLevel level) {
  final scheme = Theme.of(context).colorScheme;
  return switch (level) {
    LogLevel.trace => scheme.outline,
    LogLevel.debug => scheme.tertiary,
    LogLevel.information => scheme.primary,
    LogLevel.warning => Colors.orange.shade800,
    LogLevel.error || LogLevel.critical => scheme.error,
    LogLevel.none => scheme.outline,
  };
}

class _EventsTab extends StatefulWidget {
  const _EventsTab({required this.store, required this.settings});

  final AppLogStore store;
  final LoggingSettings settings;

  @override
  State<_EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<_EventsTab> {
  LogLevel? _displayLevel;
  String? _displayCategory;
  String _query = '';

  List<AppLogRecord> _filtered() {
    final query = _query.trim().toLowerCase();
    final records = widget.store.records.reversed.where((record) {
      final level = _displayLevel;
      if (level != null && record.level.value < level.value) return false;
      final category = _displayCategory;
      if (category != null && record.category != category) return false;
      if (query.isNotEmpty &&
          !record.message.toLowerCase().contains(query) &&
          !record.category.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    });
    return records.toList();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, widget.settings]),
    builder: (context, _) {
      final records = _filtered();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CaptureControls(store: widget.store, settings: widget.settings),
          const Divider(height: 1),
          _FilterBar(
            categories: widget.store.categories,
            displayLevel: _displayLevel,
            displayCategory: _displayCategory,
            onLevelChanged: (level) => setState(() => _displayLevel = level),
            onCategoryChanged: (category) =>
                setState(() => _displayCategory = category),
            onQueryChanged: (query) => setState(() => _query = query),
            onClear: widget.store.clear,
          ),
          const Divider(height: 1),
          Expanded(
            child: records.isEmpty
                ? const _Unavailable('No log records match.')
                : ListView.builder(
                    itemCount: records.length,
                    itemBuilder: (context, index) =>
                        _RecordTile(record: records[index]),
                  ),
          ),
        ],
      );
    },
  );
}

/// The capture-side controls: what gets recorded at all.
///
/// Collapsed by default so the list stays the focus; expanding reveals the
/// global minimum level and per-category overrides, which apply immediately
/// to every log provider (in-app store and debug console alike).
class _CaptureControls extends StatelessWidget {
  const _CaptureControls({required this.store, required this.settings});

  final AppLogStore store;
  final LoggingSettings settings;

  @override
  Widget build(BuildContext context) {
    final overrides = settings.categoryLevels;
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const Icon(Icons.tune),
      title: const Text('Capture levels'),
      subtitle: Text(
        'Default ${_levelLabel(settings.minimumLevel)}'
        '${overrides.isEmpty ? '' : ' · ${overrides.length} overrides'}',
        style: theme.textTheme.bodySmall,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Default level')),
            DropdownButton<LogLevel>(
              value: settings.minimumLevel,
              isDense: true,
              items: [
                for (final level in _pickableLevels)
                  DropdownMenuItem(
                    value: level,
                    child: Text(_levelLabel(level)),
                  ),
              ],
              onChanged: (level) {
                if (level != null) settings.setMinimumLevel(level);
              },
            ),
            // Balances the trailing delete button on override rows so the
            // dropdowns line up.
            const SizedBox(width: 48),
          ],
        ),
        for (final entry in overrides.entries)
          _OverrideRow(
            category: entry.key,
            level: entry.value,
            settings: settings,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: _AddOverrideButton(store: store, settings: settings),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Trace includes full request and response payloads and can be '
            'noisy; overrides also match dotted sub-categories.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _OverrideRow extends StatelessWidget {
  const _OverrideRow({
    required this.category,
    required this.level,
    required this.settings,
  });

  final String category;
  final LogLevel level;
  final LoggingSettings settings;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(category, overflow: TextOverflow.ellipsis)),
      DropdownButton<LogLevel>(
        value: level,
        isDense: true,
        items: [
          for (final choice in [..._pickableLevels, LogLevel.none])
            DropdownMenuItem(value: choice, child: Text(_levelLabel(choice))),
        ],
        onChanged: (choice) {
          if (choice != null) settings.setCategoryLevel(category, choice);
        },
      ),
      IconButton(
        tooltip: 'Remove override',
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => settings.setCategoryLevel(category, null),
      ),
    ],
  );
}

class _AddOverrideButton extends StatelessWidget {
  const _AddOverrideButton({required this.store, required this.settings});

  final AppLogStore store;
  final LoggingSettings settings;

  @override
  Widget build(BuildContext context) {
    final candidates = store.categories
        .where((category) => !settings.categoryLevels.containsKey(category))
        .toList();
    return PopupMenuButton<String>(
      enabled: candidates.isNotEmpty,
      tooltip: 'Override the level for one category',
      onSelected: (category) =>
          settings.setCategoryLevel(category, LogLevel.trace),
      itemBuilder: (context) => [
        for (final category in candidates)
          PopupMenuItem(value: category, child: Text(category)),
      ],
      child: IgnorePointer(
        child: TextButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: Text(
            candidates.isEmpty
                ? 'Add category override (none seen yet)'
                : 'Add category override',
          ),
          onPressed: candidates.isEmpty ? null : () {},
        ),
      ),
    );
  }
}

/// Display-side filters; these narrow the list without changing what is
/// captured.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.categories,
    required this.displayLevel,
    required this.displayCategory,
    required this.onLevelChanged,
    required this.onCategoryChanged,
    required this.onQueryChanged,
    required this.onClear,
  });

  final Set<String> categories;
  final LogLevel? displayLevel;
  final String? displayCategory;
  final ValueChanged<LogLevel?> onLevelChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search logs',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: onQueryChanged,
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<LogLevel?>(
          value: displayLevel,
          hint: const Text('Level'),
          isDense: true,
          items: [
            const DropdownMenuItem<LogLevel?>(child: Text('All levels')),
            for (final level in _pickableLevels)
              DropdownMenuItem<LogLevel?>(
                value: level,
                child: Text('≥ ${_levelLabel(level)}'),
              ),
          ],
          onChanged: onLevelChanged,
        ),
        const SizedBox(width: 8),
        DropdownButton<String?>(
          value: displayCategory,
          hint: const Text('Category'),
          isDense: true,
          items: [
            const DropdownMenuItem<String?>(child: Text('All categories')),
            for (final category in categories)
              DropdownMenuItem<String?>(
                value: category,
                child: Text(category, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onCategoryChanged,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Clear log',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: onClear,
        ),
      ],
    ),
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final AppLogRecord record;

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _levelColor(context, record.level);
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 52,
        child: Text(
          _levelLabel(record.level).toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        record.message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
      subtitle: Text(
        '${_time(record.timestamp)} · ${record.category}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _showDetail(context),
    );
  }

  void _showDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_levelLabel(record.level)} · ${record.category}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              [
                record.message,
                if (record.error != null) '\nError: ${record.error}',
              ].join('\n'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: record.message));
              if (!context.mounted) return;
              Navigator.of(context).pop();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Log entry copied')));
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

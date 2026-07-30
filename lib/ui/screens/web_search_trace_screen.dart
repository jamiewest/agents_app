// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Inspects the web tool requests captured by [WebSearchTraceLog]: one row
/// per `web_search` or `open_web_page` call, newest first, with the full
/// HTTP details behind a tap.
class WebSearchTraceScreen extends StatelessWidget {
  /// Creates a [WebSearchTraceScreen].
  const WebSearchTraceScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final log = services.getRequiredService<WebSearchTraceLog>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web request traces'),
        actions: [
          IconButton(
            tooltip: 'Clear captured requests',
            icon: const Icon(LucideIcons.trash2300),
            onPressed: log.clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          if (log.events.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  log.isEnabled
                      ? 'No requests captured yet. Ask an agent to search '
                            'the web or open a page.'
                      : 'Tracing is off. Turn it on under Settings › Web '
                            'search to start capturing requests.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final events = log.events;
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: events.length,
            itemBuilder: (context, index) => _EventTile(event: events[index]),
          );
        },
      ),
    );
  }
}

/// One captured request: the query or URL, with outcome details beneath.
class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final WebSearchTraceEvent event;

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = event.error != null || event.outcome == 'httpError';
    return ListTile(
      dense: true,
      leading: Icon(
        event.tool == 'web_search'
            ? LucideIcons.search300
            : LucideIcons.globe300,
        size: 20,
        color: failed ? theme.colorScheme.error : null,
      ),
      title: Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          _time(event.capturedAt),
          event.tool,
          event.outcome,
          if (event.httpStatusCode case final status?) 'HTTP $status',
          '${event.duration.inMilliseconds} ms',
          if (event.resultCount case final count?)
            count == 1 ? '1 result' : '$count results',
        ].join(' · '),
        style: theme.textTheme.labelSmall?.copyWith(
          color: failed
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _showDetail(context),
    );
  }

  void _showDetail(BuildContext context) {
    final detail = event.describe();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(event.tool),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(LucideIcons.copy300, size: 18),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: detail));
              if (!context.mounted) return;
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trace event copied')),
              );
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

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../wearable/pipeline/wearable_memory.dart';
import '../../wearable/wearable_service.dart';

/// Audit view of everything in wearable memory: what the distiller saved,
/// when it was observed, and where it came from. Entries can be deleted
/// individually.
class WearableMemoriesScreen extends StatefulWidget {
  /// Creates a [WearableMemoriesScreen].
  const WearableMemoriesScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<WearableMemoriesScreen> createState() => _WearableMemoriesScreenState();
}

class _WearableMemoriesScreenState extends State<WearableMemoriesScreen> {
  late final WearableMemoryStore _memory = widget.services
      .getRequiredService<WearableService>()
      .memory;

  late Future<List<WearableMemoryEntry>> _entries = _memory.all();

  void _refresh() {
    setState(() => _entries = _memory.all());
  }

  Future<void> _delete(WearableMemoryEntry entry) async {
    await _memory.delete(entry.key);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wearable memories'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: FutureBuilder<List<WearableMemoryEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load: ${snapshot.error}'));
          }
          final entries = snapshot.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) {
            return const Center(
              child: Text('No wearable memories saved yet.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: entries.length,
            itemBuilder: (context, index) =>
                _MemoryTile(entry: entries[index], onDelete: _delete),
          );
        },
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.entry, required this.onDelete});

  final WearableMemoryEntry entry;
  final ValueChanged<WearableMemoryEntry> onDelete;

  static final _sourceIcons = {
    'distilled': Symbols.psychology,
    'transcript': Symbols.graphic_eq,
    'image': Symbols.photo_camera,
  };

  String _timeRange(BuildContext context) {
    if (entry.startEpochMs == 0) return 'unknown time';
    final start = DateTime.fromMillisecondsSinceEpoch(entry.startEpochMs);
    final end = DateTime.fromMillisecondsSinceEpoch(entry.endEpochMs);
    final date =
        '${start.year}-${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';
    final from = TimeOfDay.fromDateTime(start).format(context);
    if (entry.endEpochMs <= entry.startEpochMs) return '$date $from';
    final to = TimeOfDay.fromDateTime(end).format(context);
    return '$date $from – $to';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(_sourceIcons[entry.source] ?? Symbols.memory),
        title: Text(entry.content),
        subtitle: Text('${entry.source} · ${_timeRange(context)}'),
        trailing: IconButton(
          icon: const Icon(Symbols.delete),
          tooltip: 'Delete this memory',
          onPressed: () => onDelete(entry),
        ),
      ),
    );
  }
}

/// Time-addressable, semantically searchable memory of what the wearable
/// saw and heard.
///
/// A dedicated vector collection rather than any agent's chat memory: chat
/// memory is scoped per agent + session, but wearable observations must be
/// recallable by every agent (the phase-3 device tools search this store).
library;

import 'package:extensions/vector_data.dart';

/// Field names for wearable memory entries.
abstract final class WearableMemoryRecords {
  /// The vector-store collection name (stored as `memory.wearable_memory`).
  static const String collectionName = 'wearable_memory';

  /// Unique entry key.
  static const String keyField = 'Key';

  /// The distilled note or raw transcript/description text.
  static const String contentField = 'Content';

  /// Text the scorer embeds for semantic search.
  static const String embeddingField = 'ContentEmbedding';

  /// Start of the observed time range, Unix ms.
  static const String startEpochMsField = 'startEpochMs';

  /// End of the observed time range, Unix ms.
  static const String endEpochMsField = 'endEpochMs';

  /// `distilled`, `transcript`, or `image`.
  static const String sourceField = 'source';

  /// ISO-8601 UTC write time.
  static const String createdAtField = 'createdAt';
}

/// One recalled wearable memory.
class WearableMemoryEntry {
  WearableMemoryEntry._(Map<String, Object?> record, this.score)
    : key = record[WearableMemoryRecords.keyField] as String? ?? '',
      content = record[WearableMemoryRecords.contentField] as String? ?? '',
      startEpochMs =
          (record[WearableMemoryRecords.startEpochMsField] as num?)?.toInt() ??
          0,
      endEpochMs =
          (record[WearableMemoryRecords.endEpochMsField] as num?)?.toInt() ?? 0,
      source = record[WearableMemoryRecords.sourceField] as String? ?? '';

  /// Store key of the entry (for deletion).
  final String key;

  /// The remembered text.
  final String content;

  /// Observed time range start, Unix ms.
  final int startEpochMs;

  /// Observed time range end, Unix ms.
  final int endEpochMs;

  /// How the entry was produced (`distilled`, `transcript`, `image`).
  final String source;

  /// Search relevance, when produced by [WearableMemoryStore.search].
  final double score;
}

/// Append/search store for wearable observations.
class WearableMemoryStore {
  /// Creates a [WearableMemoryStore] over [vectorStore].
  WearableMemoryStore(VectorStore vectorStore, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      _collection = vectorStore.getDynamicCollection(
        WearableMemoryRecords.collectionName,
        VectorStoreCollectionDefinition(
          properties: [
            VectorStoreKeyProperty(WearableMemoryRecords.keyField),
            VectorStoreDataProperty(WearableMemoryRecords.contentField),
            VectorStoreDataProperty(WearableMemoryRecords.startEpochMsField),
            VectorStoreDataProperty(WearableMemoryRecords.endEpochMsField),
            VectorStoreDataProperty(WearableMemoryRecords.sourceField),
            VectorStoreVectorProperty(
              WearableMemoryRecords.embeddingField,
              dimensions: 1536,
            ),
          ],
        ),
      );

  final VectorStoreCollection<String, Map<String, Object?>> _collection;
  final DateTime Function() _now;
  bool _ensured = false;

  Future<void> _ensure() async {
    if (_ensured) return;
    await _collection.ensureCollectionExistsAsync();
    _ensured = true;
  }

  /// Appends one observation covering [startEpochMs]–[endEpochMs].
  Future<void> append({
    required String content,
    required int startEpochMs,
    required int endEpochMs,
    required String source,
  }) async {
    if (content.trim().isEmpty) return;
    await _ensure();
    final now = _now();
    await _collection.upsertAsync({
      WearableMemoryRecords.keyField:
          '${now.microsecondsSinceEpoch}-$startEpochMs',
      WearableMemoryRecords.contentField: content,
      // The vector store embeds the raw text carried by the vector field.
      WearableMemoryRecords.embeddingField: content,
      WearableMemoryRecords.startEpochMsField: startEpochMs,
      WearableMemoryRecords.endEpochMsField: endEpochMs,
      WearableMemoryRecords.sourceField: source,
      WearableMemoryRecords.createdAtField: now.toUtc().toIso8601String(),
    });
  }

  /// Searches by meaning, optionally restricted to a time window.
  Future<List<WearableMemoryEntry>> search(
    String query, {
    int top = 5,
    int? fromEpochMs,
    int? toEpochMs,
  }) => _query(query, top: top, fromEpochMs: fromEpochMs, toEpochMs: toEpochMs);

  /// Everything observed in a time window, oldest first.
  Future<List<WearableMemoryEntry>> inRange(
    int fromEpochMs,
    int toEpochMs, {
    int top = 100,
  }) async {
    final entries = await _query(
      '',
      top: top,
      fromEpochMs: fromEpochMs,
      toEpochMs: toEpochMs,
    );
    entries.sort((a, b) => a.startEpochMs.compareTo(b.startEpochMs));
    return entries;
  }

  /// All stored entries, newest first (for the audit UI). [top] caps the
  /// result; the store is expected to stay small (distilled notes).
  Future<List<WearableMemoryEntry>> all({int top = 500}) async {
    await _ensure();
    final entries = <WearableMemoryEntry>[];
    await for (final record in _collection.getFilteredAsync(top: top)) {
      entries.add(WearableMemoryEntry._(record, 0));
    }
    entries.sort((a, b) => b.startEpochMs.compareTo(a.startEpochMs));
    return entries;
  }

  /// Deletes a single entry by its [WearableMemoryEntry.key].
  Future<void> delete(String key) async {
    await _ensure();
    await _collection.deleteAsync(key);
  }

  /// Deletes every stored entry; returns how many were removed.
  Future<int> clear() async {
    await _ensure();
    var removed = 0;
    // Loop: getFilteredAsync may cap results below the total count.
    while (true) {
      final keys = <String>[];
      await for (final record in _collection.getFilteredAsync(top: 500)) {
        final key = record[WearableMemoryRecords.keyField] as String?;
        if (key != null) keys.add(key);
      }
      if (keys.isEmpty) return removed;
      await _collection.deleteBatchAsync(keys);
      removed += keys.length;
    }
  }

  Future<List<WearableMemoryEntry>> _query(
    String query, {
    required int top,
    int? fromEpochMs,
    int? toEpochMs,
  }) async {
    await _ensure();
    // Time windows are filtered here (the record-store backend only supports
    // equality filters), so over-fetch before windowing.
    final results = _collection.searchAsync(query, top: 1000);
    final entries = <WearableMemoryEntry>[];
    await for (final result in results) {
      final entry = WearableMemoryEntry._(result.record, result.score ?? 0);
      if (fromEpochMs != null && entry.endEpochMs < fromEpochMs) continue;
      if (toEpochMs != null && entry.startEpochMs > toEpochMs) continue;
      entries.add(entry);
      if (entries.length >= top) break;
    }
    return entries;
  }
}

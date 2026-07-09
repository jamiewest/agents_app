/// Durable archive of offloaded captures (the pipeline's durable point:
/// once a capture has a row here and its file on disk, everything after is
/// retry-safe from persisted state).
library;

import 'package:agents_flutter/agents_flutter.dart';

import '../protocol/protocol.dart';

/// Field/collection names for archived wearable captures.
abstract final class CaptureRecords {
  /// The [RecordStore] collection holding capture rows.
  static const String collection = 'wearable_captures';

  /// Lowercase MAC of the device that captured the file.
  static const String deviceIdField = 'deviceId';

  /// `wav` or `jpg`.
  static const String kindField = 'kind';

  /// Capture start in Unix ms (stamped with receipt time when the device
  /// clock was never synced — see [approximateField]).
  static const String startEpochMsField = 'startEpochMs';

  /// True when [startEpochMsField] is receipt time, not device time.
  static const String approximateField = 'timestampApproximate';

  /// Audio duration in ms; 0 for stills.
  static const String durationMsField = 'durationMs';

  /// Absolute path of the downloaded file.
  static const String filePathField = 'filePath';

  /// File size in bytes.
  static const String sizeField = 'sizeBytes';

  /// Processing state: one of [statusPending], [statusDone], [statusFailed].
  static const String statusField = 'status';

  /// Number of processing attempts so far.
  static const String attemptsField = 'attempts';

  /// Transcript (wav) or description (jpg) once processed.
  static const String resultTextField = 'resultText';

  /// Last processing error, when [statusField] is failed.
  static const String errorField = 'error';

  /// Unix ms when processing finished.
  static const String processedAtEpochMsField = 'processedAtEpochMs';

  /// Awaiting transcription/description.
  static const String statusPending = 'pending';

  /// Processed; [resultTextField] holds the output.
  static const String statusDone = 'done';

  /// Gave up after [CaptureArchive.maxAttempts] attempts.
  static const String statusFailed = 'failed';
}

/// One archived capture row.
class ArchivedCapture {
  ArchivedCapture._(this.id, Map<String, Object?> value)
    : deviceId = value[CaptureRecords.deviceIdField] as String? ?? '',
      kind = value[CaptureRecords.kindField] as String? ?? '',
      startEpochMs =
          (value[CaptureRecords.startEpochMsField] as num?)?.toInt() ?? 0,
      timestampApproximate =
          value[CaptureRecords.approximateField] as bool? ?? false,
      durationMs =
          (value[CaptureRecords.durationMsField] as num?)?.toInt() ?? 0,
      filePath = value[CaptureRecords.filePathField] as String? ?? '',
      status =
          value[CaptureRecords.statusField] as String? ??
          CaptureRecords.statusPending,
      attempts = (value[CaptureRecords.attemptsField] as num?)?.toInt() ?? 0,
      resultText = value[CaptureRecords.resultTextField] as String?;

  /// Archive row id (`<deviceId>-<captureId>`).
  final String id;

  /// Source device.
  final String deviceId;

  /// `wav` or `jpg`.
  final String kind;

  /// Capture start in Unix ms.
  final int startEpochMs;

  /// Whether [startEpochMs] is receipt time rather than device time.
  final bool timestampApproximate;

  /// Audio duration in ms; 0 for stills.
  final int durationMs;

  /// Downloaded file location.
  final String filePath;

  /// Processing state.
  final String status;

  /// Processing attempts so far.
  final int attempts;

  /// Transcript or description, when done.
  final String? resultText;
}

/// Store of offloaded captures and their processing state.
class CaptureArchive {
  /// Creates a [CaptureArchive] over [records].
  CaptureArchive(this._records, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// Attempts before a capture is marked failed.
  static const int maxAttempts = 3;

  final RecordStore _records;
  final DateTime Function() _now;

  static String _id(String deviceId, int captureId) => '$deviceId-$captureId';

  /// Records a downloaded capture as pending processing. Epoch-0 entries
  /// (device never time-synced) are stamped with receipt time and flagged
  /// approximate. Idempotent per (device, capture id) — re-downloads after
  /// a crashed sync overwrite the same row.
  Future<ArchivedCapture> recordDownloaded({
    required String deviceId,
    required ManifestEntry entry,
    required String filePath,
  }) async {
    final approximate = !entry.hasRealTimestamp;
    final startEpochMs = approximate
        ? _now().millisecondsSinceEpoch - entry.durationMs
        : entry.startEpochMs;
    final id = _id(deviceId, entry.id);
    final value = <String, Object?>{
      CaptureRecords.deviceIdField: deviceId,
      CaptureRecords.kindField: entry.kind.name,
      CaptureRecords.startEpochMsField: startEpochMs,
      CaptureRecords.approximateField: approximate,
      CaptureRecords.durationMsField: entry.durationMs,
      CaptureRecords.filePathField: filePath,
      CaptureRecords.sizeField: entry.size,
      CaptureRecords.statusField: CaptureRecords.statusPending,
      CaptureRecords.attemptsField: 0,
    };
    await _records.put(CaptureRecords.collection, id, value);
    return ArchivedCapture._(id, value);
  }

  /// Pending captures, oldest first.
  Future<List<ArchivedCapture>> pending() async {
    final records = await _records.query(
      CaptureRecords.collection,
      query: const RecordQuery(
        equals: {CaptureRecords.statusField: CaptureRecords.statusPending},
        orderBy: CaptureRecords.startEpochMsField,
      ),
    );
    return [for (final r in records) ArchivedCapture._(r.id, r.value)];
  }

  /// Marks a capture processed with its transcript/description.
  Future<void> markDone(String id, String resultText) => _update(id, (value) {
    value[CaptureRecords.statusField] = CaptureRecords.statusDone;
    value[CaptureRecords.resultTextField] = resultText;
    value[CaptureRecords.processedAtEpochMsField] =
        _now().millisecondsSinceEpoch;
  });

  /// Records a failed attempt; the capture stays pending until
  /// [maxAttempts], then is marked failed.
  Future<void> markFailed(String id, String error) => _update(id, (value) {
    final attempts =
        ((value[CaptureRecords.attemptsField] as num?)?.toInt() ?? 0) + 1;
    value[CaptureRecords.attemptsField] = attempts;
    value[CaptureRecords.errorField] = error;
    if (attempts >= maxAttempts) {
      value[CaptureRecords.statusField] = CaptureRecords.statusFailed;
    }
  });

  Future<void> _update(
    String id,
    void Function(Map<String, Object?> value) mutate,
  ) async {
    final existing = await _records.get(CaptureRecords.collection, id);
    if (existing == null) return;
    final value = Map<String, Object?>.of(existing);
    mutate(value);
    await _records.put(CaptureRecords.collection, id, value);
  }

  /// All captures, newest first (for UI).
  Stream<List<ArchivedCapture>> watchAll() => _records
      .watch(
        CaptureRecords.collection,
        query: const RecordQuery(
          orderBy: CaptureRecords.startEpochMsField,
          descending: true,
        ),
      )
      .map(
        (records) => [
          for (final r in records) ArchivedCapture._(r.id, r.value),
        ],
      );
}

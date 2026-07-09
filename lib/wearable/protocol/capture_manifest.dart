/// Manifest models (PROTOCOL.md §4–§5).
library;

/// The kind of a captured file.
enum CaptureKind {
  /// 16 kHz / 16-bit / mono RIFF WAV audio segment.
  wav,

  /// OV2640 JPEG still.
  jpg;

  static CaptureKind? _parse(Object? value) => switch (value) {
    'wav' => CaptureKind.wav,
    'jpg' => CaptureKind.jpg,
    _ => null,
  };
}

/// One finalized capture offered for download.
class ManifestEntry {
  /// Creates a [ManifestEntry].
  const ManifestEntry({
    required this.id,
    required this.kind,
    required this.startEpochMs,
    required this.durationMs,
    required this.size,
    required this.crc32,
  });

  /// Decodes a manifest entry object; returns `null` for entries with an
  /// unknown kind (forward compatibility — skip, don't fail the sync).
  static ManifestEntry? fromJson(Map<String, Object?> json) {
    final kind = CaptureKind._parse(json['kind']);
    if (kind == null) return null;
    return ManifestEntry(
      id: (json['id'] as num).toInt(),
      kind: kind,
      startEpochMs: (json['start_epoch_ms'] as num?)?.toInt() ?? 0,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num).toInt(),
      crc32: (json['crc32'] as num).toInt(),
    );
  }

  /// Monotonic capture id (device NVS-persisted).
  final int id;

  /// File kind.
  final CaptureKind kind;

  /// Capture start in Unix ms; `0` = captured before first time-sync, and
  /// the client must stamp it with sync-receipt time and flag approximate.
  final int startEpochMs;

  /// Audio duration in ms; `0` for stills.
  final int durationMs;

  /// File size in bytes.
  final int size;

  /// IEEE (zlib) CRC-32 of the entire file.
  final int crc32;

  /// Whether the device had wall-clock time when this was captured.
  bool get hasRealTimestamp => startEpochMs != 0;
}

/// A decoded `GET /manifest` response.
class DeviceManifest {
  /// Creates a [DeviceManifest].
  const DeviceManifest({
    required this.deviceId,
    required this.epochMs,
    required this.entries,
  });

  /// Decodes the manifest response body.
  factory DeviceManifest.fromJson(Map<String, Object?> json) => DeviceManifest(
    deviceId: json['device_id'] as String? ?? '',
    epochMs: (json['epoch_ms'] as num?)?.toInt() ?? 0,
    entries: [
      for (final raw in (json['files'] as List<Object?>? ?? const []))
        ?ManifestEntry.fromJson(raw! as Map<String, Object?>),
    ],
  );

  /// Lowercase MAC without separators.
  final String deviceId;

  /// Device wall-clock at response time; `0` if never synced.
  final int epochMs;

  /// Downloadable captures, oldest first.
  final List<ManifestEntry> entries;
}

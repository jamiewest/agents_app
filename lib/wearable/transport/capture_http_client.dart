/// HTTP bulk-plane client (PROTOCOL.md §5): manifest, CRC-verified
/// downloads with Range resume, and ack.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../protocol/protocol.dart';

/// Thrown when a downloaded file fails size or CRC verification.
class CaptureIntegrityException implements Exception {
  /// Creates a [CaptureIntegrityException].
  const CaptureIntegrityException(this.message);

  /// What failed.
  final String message;

  @override
  String toString() => 'CaptureIntegrityException: $message';
}

/// Result of `POST /ack`.
class AckResult {
  /// Creates an [AckResult].
  const AckResult({required this.freedBytes, required this.fileCount});

  /// Bytes freed on the device's SD card.
  final int freedBytes;

  /// Un-offloaded files remaining on the device.
  final int fileCount;
}

/// Client for one device HTTP session ([endpoint]'s token rotates per
/// `wifi_join`, so a client is only valid for the session it was built for).
class CaptureHttpClient {
  /// Creates a [CaptureHttpClient]; pass [client] to fake the network.
  CaptureHttpClient(this.endpoint, {http.Client? client})
    : _client = client ?? http.Client();

  /// The device endpoint (from the BLE Endpoint characteristic).
  final DeviceEndpoint endpoint;
  final http.Client _client;

  Map<String, String> get _auth => {
    'Authorization': endpoint.authorizationHeader,
  };

  Uri _uri(String path) => endpoint.baseUri.replace(path: path);

  /// Fetches the manifest of downloadable captures.
  Future<DeviceManifest> fetchManifest() async {
    final response = await _client.get(_uri('/manifest'), headers: _auth);
    if (response.statusCode != 200) {
      throw http.ClientException('manifest: HTTP ${response.statusCode}');
    }
    return DeviceManifest.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  }

  /// Downloads one capture, resuming with Range on interruption, and
  /// verifies size + CRC-32 against [entry] before returning.
  Future<Uint8List> download(
    ManifestEntry entry, {
    int maxAttempts = 3,
    void Function(int received, int total)? onProgress,
  }) async {
    final buffer = BytesBuilder(copy: false);
    var attempt = 0;
    while (buffer.length < entry.size) {
      if (attempt >= maxAttempts) {
        throw CaptureIntegrityException(
          'id ${entry.id}: incomplete (${buffer.length}/${entry.size}) '
          'after $maxAttempts attempts',
        );
      }
      attempt++;
      try {
        await _fetchInto(buffer, entry, onProgress);
      } catch (e) {
        if (attempt >= maxAttempts) rethrow;
        developer.log(
          'download ${entry.id} interrupted at ${buffer.length}/'
          '${entry.size}, resuming (attempt $attempt): $e',
          name: 'wearable.http',
        );
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }

    final bytes = buffer.takeBytes();
    if (bytes.length != entry.size) {
      throw CaptureIntegrityException(
        'id ${entry.id}: size ${bytes.length} != manifest ${entry.size}',
      );
    }
    // crc32 == 0 marks entries from firmware < 0.1.1, whose CRC pass read
    // nothing (write-only handle bug). Size still guards truncation; accept
    // with a warning rather than stranding those captures on the device.
    if (entry.crc32 == 0) {
      developer.log(
        'id ${entry.id}: manifest crc is 0 (legacy firmware) — '
        'accepted unverified',
        name: 'wearable.http',
      );
      return bytes;
    }
    final crc = crc32(bytes);
    if (crc != entry.crc32) {
      throw CaptureIntegrityException(
        'id ${entry.id}: crc32 $crc != manifest ${entry.crc32}',
      );
    }
    return bytes;
  }

  Future<void> _fetchInto(
    BytesBuilder buffer,
    ManifestEntry entry,
    void Function(int received, int total)? onProgress,
  ) async {
    final request = http.Request('GET', _uri('/file/${entry.id}'))
      ..headers.addAll(_auth);
    if (buffer.length > 0) {
      request.headers['Range'] = 'bytes=${buffer.length}-';
    }
    final response = await _client.send(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw http.ClientException(
        'file ${entry.id}: HTTP ${response.statusCode}',
      );
    }
    // A 200 to a Range request means the device restarted the file.
    if (response.statusCode == 200 && buffer.length > 0) {
      buffer.clear();
    }
    await for (final chunk in response.stream) {
      buffer.add(chunk);
      onProgress?.call(buffer.length, entry.size);
      if (buffer.length >= entry.size) break;
    }
  }

  /// Acks downloaded captures; the device deletes them and frees SD space.
  /// Only call after the bytes are durably persisted locally.
  Future<AckResult> ack(List<int> ids) async {
    final response = await _client.post(
      _uri('/ack'),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode({'ids': ids}),
    );
    if (response.statusCode != 200) {
      throw http.ClientException('ack: HTTP ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, Object?>;
    return AckResult(
      freedBytes: (json['freed_bytes'] as num?)?.toInt() ?? 0,
      fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Releases the underlying HTTP connection pool.
  void close() => _client.close();
}

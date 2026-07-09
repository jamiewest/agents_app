import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/transport/capture_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A local stand-in for the firmware's HTTP server (PROTOCOL.md §5),
/// including auth, Range handling, and mid-transfer connection drops.
class FakeFirmwareServer {
  FakeFirmwareServer(this.token);

  final String token;
  late HttpServer _server;
  final Map<int, Uint8List> files = {};
  final List<List<int>> acks = [];

  /// When > 0, the next [dropRequests] file responses destroy the socket
  /// after [dropAfterBytes] bytes.
  int dropAfterBytes = 0;

  /// How many file requests remain to be dropped.
  int dropRequests = 0;

  /// When true, ignore Range headers and always send from byte 0.
  bool ignoreRange = false;

  int get port => _server.port;

  DeviceEndpoint get endpoint =>
      DeviceEndpoint(ip: '127.0.0.1', port: port, token: token);

  ManifestEntry entryFor(int id, {CaptureKind kind = CaptureKind.wav}) {
    final bytes = files[id]!;
    return ManifestEntry(
      id: id,
      kind: kind,
      startEpochMs: 1751990400000,
      durationMs: kind == CaptureKind.wav ? 60000 : 0,
      size: bytes.length,
      crc32: crc32(bytes),
    );
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value('Authorization') != 'Bearer $token') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final segments = request.uri.pathSegments;
    if (segments.length == 1 && segments[0] == 'manifest') {
      final entries = files.keys.map((id) {
        final e = entryFor(id);
        return {
          'id': e.id,
          'kind': 'wav',
          'start_epoch_ms': e.startEpochMs,
          'duration_ms': e.durationMs,
          'size': e.size,
          'crc32': e.crc32,
        };
      }).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'device_id': 'fake00000000',
          'epoch_ms': 1751990400000,
          'files': entries,
        }),
      );
      await request.response.close();
      return;
    }
    if (segments.length == 2 && segments[0] == 'file') {
      final bytes = files[int.parse(segments[1])];
      if (bytes == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      var start = 0;
      final range = request.headers.value('Range');
      if (range != null && range.startsWith('bytes=') && !ignoreRange) {
        start = int.parse(range.substring(6).split('-').first);
        request.response.statusCode = 206;
      }
      final slice = bytes.sublist(start);
      if (dropRequests > 0 && slice.length > dropAfterBytes) {
        dropRequests--;
        request.response.contentLength = slice.length;
        // Detach writes the headers; then send a partial body and cut the
        // connection to simulate the device going out of WiFi range.
        final socket = await request.response.detachSocket();
        socket.add(slice.sublist(0, dropAfterBytes));
        await socket.flush();
        socket.destroy();
        return;
      }
      request.response.add(slice);
      await request.response.close();
      return;
    }
    if (segments.length == 1 && segments[0] == 'ack') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final ids = (body['ids']! as List).cast<int>();
      acks.add(ids);
      var freed = 0;
      for (final id in ids) {
        freed += files.remove(id)?.length ?? 0;
      }
      request.response.write(
        jsonEncode({'freed_bytes': freed, 'file_count': files.length}),
      );
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

Uint8List randomBytes(int length, [int seed = 42]) {
  final rng = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

void main() {
  late FakeFirmwareServer server;
  late CaptureHttpClient client;

  setUp(() async {
    server = FakeFirmwareServer('test-token');
    await server.start();
    client = CaptureHttpClient(server.endpoint);
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  test('fetches and decodes the manifest', () async {
    server.files[7] = randomBytes(1024);
    final manifest = await client.fetchManifest();
    expect(manifest.deviceId, 'fake00000000');
    expect(manifest.entries, hasLength(1));
    expect(manifest.entries.single.id, 7);
    expect(manifest.entries.single.size, 1024);
  });

  test('downloads and verifies a file', () async {
    server.files[1] = randomBytes(64 * 1024);
    final progress = <int>[];
    final bytes = await client.download(
      server.entryFor(1),
      onProgress: (received, total) => progress.add(received),
    );
    expect(bytes, server.files[1]);
    expect(progress.last, 64 * 1024);
  });

  test('resumes with Range after a mid-transfer drop', () async {
    server.files[2] = randomBytes(96 * 1024);
    final entry = server.entryFor(2);
    server.dropAfterBytes = 30 * 1024;
    server.dropRequests = 2;
    // First attempt drops at 30 KiB; the resume request starts there, is
    // itself dropped once more, and the third completes the tail.
    final bytes = await client.download(entry);
    expect(bytes.length, entry.size);
    expect(crc32(bytes), entry.crc32);
  });

  test(
    'recovers when the device ignores Range and restarts from zero',
    () async {
      server.files[3] = randomBytes(48 * 1024);
      final entry = server.entryFor(3);
      server.ignoreRange = true;
      server.dropAfterBytes = 40 * 1024;
      server.dropRequests = 1;
      // First attempt drops at 40 KiB. The retry sends a Range header, but
      // the server replies 200 from byte zero — the client must discard its
      // partial buffer and take the full restart.
      final bytes = await client.download(entry);
      expect(crc32(bytes), entry.crc32);
    },
  );

  test('accepts manifest crc 0 as unverified (legacy firmware)', () async {
    server.files[8] = randomBytes(512);
    final real = server.entryFor(8);
    final legacy = ManifestEntry(
      id: real.id,
      kind: real.kind,
      startEpochMs: real.startEpochMs,
      durationMs: real.durationMs,
      size: real.size,
      crc32: 0,
    );
    final bytes = await client.download(legacy);
    expect(bytes, server.files[8]);
  });

  test('throws on CRC mismatch', () async {
    server.files[4] = randomBytes(1024);
    final entry = server.entryFor(4);
    server.files[4] = randomBytes(1024, 99); // Corrupt after manifest.
    expect(
      () => client.download(entry),
      throwsA(isA<CaptureIntegrityException>()),
    );
  });

  test('throws on auth failure', () async {
    server.files[5] = randomBytes(16);
    final bad = CaptureHttpClient(
      DeviceEndpoint(ip: '127.0.0.1', port: server.port, token: 'wrong'),
    );
    addTearDown(bad.close);
    expect(bad.fetchManifest(), throwsException);
  });

  test('acks delete files device-side', () async {
    server.files[6] = randomBytes(2048);
    server.files[7] = randomBytes(1024);
    final result = await client.ack([6, 7]);
    expect(result.freedBytes, 3072);
    expect(result.fileCount, 0);
    expect(server.acks.single, [6, 7]);
  });
}

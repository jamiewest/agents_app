/// syncNow endpoint-staleness recovery: a dead published endpoint (device
/// silently off WiFi) must trigger one wifi_leave → wifi_join rebuild and a
/// retried pull, not an opaque failure.
library;

import 'dart:io';

import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/transport/capture_http_client.dart';
import 'package:agents_app/wearable/wearable_service.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_device_transport.dart';

class _NoopEngine implements TranscriptionEngine {
  @override
  Future<String> transcribe(String path) async => '';
}

const _endpoint = DeviceEndpoint(ip: '10.0.0.9', port: 8080, token: 't');

const _emptyManifest = '{"device_id":"dev","epoch_ms":0,"files":[]}';

void main() {
  late FakeDeviceTransport transport;
  late Directory tempDir;

  WearableService buildService(http.Client Function() clientBuilder) {
    final settings = InMemoryKeyValueStore();
    return WearableService(
      records: InMemoryRecordStore(),
      scorer: const KeywordOverlapScorer(),
      agents: AgentConfigurationStore(settings),
      settings: settings,
      distillerRunner: (_, _) async => '',
      transport: transport,
      transcription: _NoopEngine(),
      resolveCapturesDirectory: () async => tempDir,
      httpClientFactory: (endpoint) =>
          CaptureHttpClient(endpoint, client: clientBuilder()),
    );
  }

  setUp(() {
    transport = FakeDeviceTransport();
    transport.endpoint = _endpoint;
    tempDir = Directory.systemTemp.createTempSync('wearable_sync_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('rebuilds the wifi session once when the endpoint is dead', () async {
    var manifestRequests = 0;
    final service = buildService(
      () => MockClient((request) async {
        manifestRequests++;
        if (manifestRequests == 1) {
          throw const SocketException('connection refused');
        }
        return http.Response(_emptyManifest, 200);
      }),
    );
    addTearDown(service.dispose);

    final result = await service.syncNow();

    expect(result.downloadedFiles, 0);
    expect(manifestRequests, 2);
    final ops = [for (final c in transport.sentCommands) c['op']];
    expect(ops, containsAllInOrder(['wifi_leave', 'wifi_join']));
  });

  test('a dead endpoint on both attempts surfaces the failure', () async {
    final service = buildService(
      () => MockClient(
        (_) async => throw const SocketException('connection refused'),
      ),
    );
    addTearDown(service.dispose);

    await expectLater(service.syncNow(), throwsA(isA<SocketException>()));
    final ops = [for (final c in transport.sentCommands) c['op']];
    // Exactly one rebuild — no retry loop.
    expect(ops.where((op) => op == 'wifi_leave'), hasLength(1));
  });

  test('non-transport failures do not trigger a wifi rebuild', () async {
    // A 200 with a manifest whose entry cannot be downloaded intact ends in
    // CaptureIntegrityException; rebuilding the session would not help.
    final service = buildService(
      () => MockClient((request) async {
        if (request.url.path == '/manifest') {
          return http.Response(
            '{"device_id":"dev","epoch_ms":0,"files":['
            '{"id":1,"kind":"jpg","start_epoch_ms":0,"duration_ms":0,'
            '"size":4,"crc32":123}]}',
            200,
          );
        }
        // Short body: size check can never be satisfied.
        return http.Response.bytes(const [1], 200);
      }),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.syncNow(),
      throwsA(isA<CaptureIntegrityException>()),
    );
    final ops = [for (final c in transport.sentCommands) c['op']];
    expect(ops, isNot(contains('wifi_leave')));
  });
}

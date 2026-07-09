import 'dart:convert';

import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('crc32', () {
    test('matches the IEEE check value', () {
      // The canonical CRC-32 test vector.
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('is chunkable', () {
      final whole = crc32(ascii.encode('123456789'));
      final first = crc32(ascii.encode('1234'));
      expect(crc32(ascii.encode('56789'), first), whole);
    });

    test('empty input is zero', () {
      expect(crc32(const []), 0);
    });
  });

  group('DeviceStatus', () {
    test('decodes a full status payload', () {
      final status = DeviceStatus.fromBytes(
        utf8.encode(
          '{"fw":"0.1.0","epoch_ms":1751990400000,"recording":true,'
          '"battery_pct":87,"charging":false,"buffered_bytes":18732211,'
          '"file_count":32,"wifi":"up","checkin":true}',
        ),
      );
      expect(status.firmwareVersion, '0.1.0');
      expect(status.epochMs, 1751990400000);
      expect(status.recording, isTrue);
      expect(status.batteryPercent, 87);
      expect(status.bufferedBytes, 18732211);
      expect(status.fileCount, 32);
      expect(status.wifi, DeviceWifiState.up);
      expect(status.checkinRequested, isTrue);
      expect(status.isTimeSynced, isTrue);
    });

    test('epoch 0 means never time-synced', () {
      final status = DeviceStatus.fromJson(const {'epoch_ms': 0});
      expect(status.isTimeSynced, isFalse);
    });

    test('unknown wifi state degrades to off', () {
      final status = DeviceStatus.fromJson(const {'wifi': 'warp-speed'});
      expect(status.wifi, DeviceWifiState.off);
    });
  });

  group('CaptureCommands', () {
    Map<String, Object?> decode(List<int> bytes) =>
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

    test('time_sync carries epoch', () {
      expect(decode(CaptureCommands.timeSync(1751990400000)), {
        'op': 'time_sync',
        'epoch_ms': 1751990400000,
      });
    });

    test('set_policy omits absent fields', () {
      expect(decode(CaptureCommands.setPolicy(segmentSeconds: 30)), {
        'op': 'set_policy',
        'segment_s': 30,
      });
    });

    test('commands fit a single 185-byte MTU write', () {
      final payloads = [
        CaptureCommands.timeSync(1751990400000),
        CaptureCommands.captureImage(),
        CaptureCommands.record(enabled: true),
        CaptureCommands.setPolicy(
          imageIntervalSeconds: 300,
          segmentSeconds: 60,
          checkinThresholdBytes: 8 * 1024 * 1024,
        ),
        CaptureCommands.wifiJoin(),
        CaptureCommands.wifiLeave(),
        CaptureCommands.flushBle(resumeId: 0xFFFFFFFE, resumeOffset: 1 << 30),
      ];
      for (final payload in payloads) {
        expect(payload.length, lessThanOrEqualTo(captureMinimumMtu - 3));
      }
    });
  });

  group('ControlResponse', () {
    test('decodes success with capture id', () {
      final rsp = ControlResponse.fromBytes(
        utf8.encode('{"op":"capture_image","ok":true,"id":1041}'),
      );
      expect(rsp.op, 'capture_image');
      expect(rsp.ok, isTrue);
      expect(rsp.captureId, 1041);
      expect(rsp.error, isNull);
    });

    test('decodes known and unknown error codes', () {
      final known = ControlResponse.fromBytes(
        utf8.encode('{"op":"wifi_join","ok":false,"err":"wifi_auth_failed"}'),
      );
      expect(known.error, CaptureControlError.wifiAuthFailed);

      final future = ControlResponse.fromBytes(
        utf8.encode('{"op":"x","ok":false,"err":"code_from_v9"}'),
      );
      expect(future.error, CaptureControlError.unknown);
    });
  });

  group('DeviceEndpoint', () {
    test('decodes a published endpoint', () {
      final endpoint = DeviceEndpoint.fromBytes(
        utf8.encode('{"ip":"192.168.1.44","port":8080,"token":"abc123"}'),
      )!;
      expect(endpoint.baseUri, Uri.parse('http://192.168.1.44:8080'));
      expect(endpoint.authorizationHeader, 'Bearer abc123');
    });

    test('empty object means wifi down', () {
      expect(DeviceEndpoint.fromBytes(utf8.encode('{}')), isNull);
      expect(DeviceEndpoint.fromBytes(const []), isNull);
    });
  });

  group('DeviceManifest', () {
    test('decodes entries and skips unknown kinds', () {
      final manifest = DeviceManifest.fromJson(
        jsonDecode('''
        {"device_id":"d4f98d3a2b10","epoch_ms":1751990400000,"files":[
          {"id":1040,"kind":"wav","start_epoch_ms":1751990400000,
           "duration_ms":60000,"size":1920044,"crc32":3405691582},
          {"id":1041,"kind":"jpg","start_epoch_ms":1751990460000,
           "duration_ms":0,"size":183001,"crc32":12345},
          {"id":1042,"kind":"holo","size":1,"crc32":2}
        ]}''')
            as Map<String, Object?>,
      );
      expect(manifest.deviceId, 'd4f98d3a2b10');
      expect(manifest.entries, hasLength(2));
      expect(manifest.entries[0].kind, CaptureKind.wav);
      expect(manifest.entries[1].kind, CaptureKind.jpg);
    });

    test('epoch-0 entries are flagged approximate', () {
      final entry = ManifestEntry.fromJson(const {
        'id': 7,
        'kind': 'wav',
        'start_epoch_ms': 0,
        'duration_ms': 60000,
        'size': 10,
        'crc32': 0,
      })!;
      expect(entry.hasRealTimestamp, isFalse);
    });
  });

  group('BleChunk', () {
    test('round-trips a data frame', () {
      final frame = <int>[
        0x10, 0x04, 0x00, 0x00, // id 1040 LE
        0x00, 0x20, 0x00, 0x00, // offset 8192 LE
        0x03, 0x00, // len 3 LE
        0xAA, 0xBB, 0xCC,
      ];
      final chunk = BleChunk.parse(frame)!;
      expect(chunk.id, 1040);
      expect(chunk.offset, 8192);
      expect(chunk.payload, [0xAA, 0xBB, 0xCC]);
      expect(chunk.isEndOfFile, isFalse);
      expect(chunk.isEndOfTransfer, isFalse);
    });

    test('zero-length payload is end of file', () {
      final chunk = BleChunk.parse(const [
        0x10,
        0x04,
        0x00,
        0x00,
        0x44,
        0x4C,
        0x1D,
        0x00,
        0x00,
        0x00,
      ])!;
      expect(chunk.isEndOfFile, isTrue);
    });

    test('sentinel id is end of transfer', () {
      final chunk = BleChunk.parse(const [
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ])!;
      expect(chunk.isEndOfTransfer, isTrue);
    });

    test('rejects truncated and length-mismatched frames', () {
      expect(BleChunk.parse(const [1, 2, 3]), isNull);
      // Header claims 5 payload bytes but only 2 follow.
      expect(
        BleChunk.parse(const [1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0xAA, 0xBB]),
        isNull,
      );
    });

    test('builds acks the device can parse', () {
      expect(buildBleAck(id: 1040, nextOffset: 0x1D4C44), [
        0x10,
        0x04,
        0x00,
        0x00,
        0x44,
        0x4C,
        0x1D,
        0x00,
      ]);
    });
  });
}
